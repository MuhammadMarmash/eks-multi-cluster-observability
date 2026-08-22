mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  cluster_name           = "obs-platform-prod-observability"
  namespace              = "telemetry"
  gateway_dns_name       = "gateway.observability.internal"
  route53_zone_id        = "Z0123456789ABCDEFGHIJ"
  nlb_subnet_ids         = ["subnet-0aaa", "subnet-0bbb", "subnet-0ccc"]
  nlb_security_group_ids = ["sg-0abcdef0123456789"]
  cert_manager_namespace = "cert-manager"
  chart_repository       = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts"
  chart_version          = "1.4.0"
  image_registry         = "123456789012.dkr.ecr.eu-west-1.amazonaws.com"
  image_repository       = "mirror/grafana/alloy"
  image_tag              = "v1.12.0"
}

run "receiver_requires_tls_and_auth_on_both_ports" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "endpoint = \"0.0.0.0:4317\"")
    error_message = "OTLP/gRPC must listen on 4317 — the only port modules/security opens."
  }

  assert {
    condition     = strcontains(output.rendered_config, "endpoint = \"0.0.0.0:4318\"")
    error_message = "OTLP/HTTP must listen on 4318."
  }

  assert {
    condition     = length(regexall("auth +=", output.rendered_config)) == 2
    error_message = "Both the grpc and http blocks must require auth. Securing only one leaves an unauthenticated ingest path on the other."
  }

  assert {
    condition     = length(regexall("cert_file +=", output.rendered_config)) == 2
    error_message = "Both listeners must terminate TLS. ADR 0002 puts termination here, not at the NLB."
  }
}

run "credentials_are_never_baked_into_the_config" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "sys.env(\"INGEST_PASSWORD\")")
    error_message = "The password must be read from the environment, not templated into the ConfigMap where kubectl get cm would print it."
  }
}

run "debug_sink_is_the_default_until_lgtm_exists" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "otelcol.exporter.debug")
    error_message = "With lgtm_enabled false the pipeline must still terminate somewhere observable."
  }

  # otelcol.exporter.debug is experimental. Alloy refuses to start when the
  # stability level does not admit a component it has been given, so this is
  # the difference between a running gateway and a CrashLoopBackOff.
  assert {
    condition     = output.values.alloy.stabilityLevel == "experimental"
    error_message = "The debug sink is an experimental component; the stability level must admit it or Alloy will not start."
  }

  assert {
    condition     = !strcontains(output.rendered_config, "otelcol.exporter.otlphttp")
    error_message = "No LGTM exporter may be rendered while lgtm_enabled is false; it would fail to connect on every batch."
  }
}

run "lgtm_exporters_appear_when_enabled" {
  command = plan

  variables {
    lgtm_enabled   = true
    mimir_endpoint = "http://mimir-nginx.lgtm.svc.cluster.local/otlp"
    loki_endpoint  = "http://loki-gateway.lgtm.svc.cluster.local/otlp"
    tempo_endpoint = "tempo-distributor.lgtm.svc.cluster.local:4317"
  }

  assert {
    condition     = strcontains(output.rendered_config, "mimir-nginx.lgtm.svc.cluster.local")
    error_message = "Metrics must route to Mimir when LGTM is enabled."
  }

  assert {
    condition     = strcontains(output.rendered_config, "loki-gateway.lgtm.svc.cluster.local")
    error_message = "Logs must route to Loki when LGTM is enabled."
  }

  assert {
    condition     = strcontains(output.rendered_config, "tempo-distributor.lgtm.svc.cluster.local:4317")
    error_message = "Traces must route to Tempo over OTLP/gRPC when LGTM is enabled."
  }

  assert {
    condition     = !strcontains(output.rendered_config, "otelcol.exporter.debug")
    error_message = "The debug sink must disappear once real backends exist; leaving it on doubles the gateway's CPU for nothing."
  }

  # With no experimental component left, the gate goes back down.
  assert {
    condition     = output.values.alloy.stabilityLevel == "generally-available"
    error_message = "With real backends every component is generally-available; the stability gate must not stay lowered."
  }
}

run "nlb_is_internal_ip_targeted_and_locked_to_our_security_group" {
  command = plan

  assert {
    condition     = kubernetes_service_v1.gateway.metadata[0].annotations["service.beta.kubernetes.io/aws-load-balancer-scheme"] == "internal"
    error_message = "An internet-facing scheme would put the ingest endpoint on the public internet, which ADR 0002 rejects outright."
  }

  assert {
    condition     = kubernetes_service_v1.gateway.metadata[0].annotations["service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"] == "ip"
    error_message = "ip targets route straight to pod ENIs; instance targets add a hop and need a NodePort."
  }

  assert {
    condition     = kubernetes_service_v1.gateway.metadata[0].annotations["service.beta.kubernetes.io/aws-load-balancer-security-groups"] == "sg-0abcdef0123456789"
    error_message = "The CIDR restriction only has teeth if the group is on the load balancer. Client IP preservation is off by default for ip targets, so a node-only attachment never sees Cluster A's address."
  }

  assert {
    condition     = kubernetes_service_v1.gateway.spec[0].type == "LoadBalancer"
    error_message = "The gateway Service must be of type LoadBalancer."
  }
}

run "dns_record_points_at_the_load_balancer" {
  command = plan

  assert {
    condition     = aws_route53_record.gateway.type == "CNAME"
    error_message = "A CNAME to the NLB's AWS name lets AWS keep resolving it to current private IPs."
  }

  assert {
    condition     = aws_route53_record.gateway.name == "gateway.observability.internal"
    error_message = "The record name must equal the certificate SAN exactly."
  }
}

run "gateway_needs_no_kubernetes_api_access" {
  command = plan

  assert {
    condition     = output.values.rbac.create == false
    error_message = "The gateway only receives and forwards. Granting it cluster read access would be privilege it never uses."
  }

  assert {
    condition     = output.values.service.enabled == false
    error_message = "The chart's own Service must be off; the NLB Service in this module carries the load balancer annotations."
  }
}

# An empty `registry` makes the chart emit "<empty>/<repository>" — a LEADING
# SLASH and an image reference Kubernetes cannot pull. It renders fine, passes
# every values assertion, and fails as ImagePullBackOff on a live cluster.
run "image_reference_has_no_leading_slash" {
  command = plan

  assert {
    condition     = output.values.image.registry != ""
    error_message = "registry must be the ECR hostname, not empty; the chart concatenates registry and repository."
  }

  assert {
    condition     = !startswith(output.values.image.repository, "/")
    error_message = "repository must be a path within the registry, with no leading slash."
  }
}

# The chart's config-reloader sidecar pulls from quay.io, which ADR 0005 forbids
# at deploy time.
run "no_unmirrored_sidecar" {
  command = plan

  assert {
    condition     = output.values.configReloader.enabled == false
    error_message = "The config-reloader sidecar pulls an unmirrored quay.io image and reloads a config that only ever changes via a Helm release."
  }
}

# The gateway is the single ingest point for the whole pipeline, and the agent
# on Cluster A only buffers for five minutes. Losing both replicas at once —
# which an unconstrained node drain will happily do — is data loss, not a blip.
run "a_node_drain_cannot_take_both_replicas" {
  command = plan

  assert {
    condition     = output.values.controller.podDisruptionBudget.enabled == true
    error_message = "With more than one replica the gateway needs a PDB, or a drain evicts every replica at once."
  }

  assert {
    condition     = output.values.controller.podDisruptionBudget.maxUnavailable == 1
    error_message = "At most one gateway replica may be unavailable during a voluntary disruption."
  }

  # `required`, not `preferred`: the soft form lets the scheduler co-locate
  # replicas under pressure, which is exactly the state a node roll creates.
  assert {
    condition     = length(output.values.controller.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution) == 1
    error_message = "Anti-affinity must be required, not preferred."
  }

  assert {
    condition     = output.values.controller.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey == "kubernetes.io/hostname"
    error_message = "Replicas must be spread across nodes; spreading by zone alone still allows two on one node."
  }
}

# A PDB on a single-replica Deployment blocks every drain outright — the node
# can never be evacuated. Gating on replicas > 1 is what keeps a scaled-down
# gateway from wedging an upgrade.
run "single_replica_gets_no_pdb" {
  command = plan

  variables {
    replicas = 1
  }

  assert {
    condition     = output.values.controller.podDisruptionBudget.enabled == false
    error_message = "A PDB with maxUnavailable 1 on a single replica makes the node undrainable."
  }
}

# An NLB puts a node in every subnet it is given and, with cross-zone off,
# each node serves only its own zone. Two replicas across three subnets
# therefore leaves one zone with no target, black-holing about a third of
# connections — an intermittent-looking fault with a configuration cause.
run "no_zone_can_black_hole_traffic" {
  command = plan

  assert {
    condition     = kubernetes_service_v1.gateway.metadata[0].annotations["service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled"] == "true"
    error_message = "With fewer replicas than subnets, cross-zone load balancing is what stops a zone without a target from black-holing connections."
  }
}
