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
  image_repository       = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/mirror/grafana/alloy"
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
