mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  cluster_name     = "obs-platform-prod-workload"
  namespace        = "telemetry"
  gateway_endpoint = "gateway.observability.internal:4317"
  gateway_ca_pem   = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
  ingest_username  = "alloy-workload"
  ingest_password  = "not-a-real-password"
  chart_repository = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts"
  chart_version    = "1.4.0"
  image_registry   = "123456789012.dkr.ecr.eu-west-1.amazonaws.com"
  image_repository = "mirror/grafana/alloy"
  image_tag        = "v1.12.0"
}

run "exports_everything_to_the_gateway_and_nowhere_else" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "endpoint = \"gateway.observability.internal:4317\"")
    error_message = "All three signals leave on one connection to the gateway."
  }

  # Matches exporter DECLARATIONS only. A bare `otelcol.exporter.` also matches
  # the `.input` references inside pipeline output blocks, which is why this
  # anchors on the quoted label that follows a declaration.
  assert {
    condition     = length(regexall("otelcol\\.exporter\\.[a-z]+ \"", output.rendered_config)) == 1
    error_message = "Exactly one exporter. ADR 0002 forbids Cluster A talking to Loki, Mimir or Tempo directly, and only 4317/4318 cross the peering link."
  }

  assert {
    condition     = !strcontains(output.rendered_config, "3100")
    error_message = "No direct Loki push port may appear; it is not open on the peering link."
  }
}

run "gateway_certificate_is_actually_verified" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "ca_file = \"/etc/alloy/certs/ca.crt\"")
    error_message = "The exporter must verify against the CA copied from Cluster B."
  }

  assert {
    condition     = !strcontains(output.rendered_config, "insecure = true")
    error_message = "The gateway connection must never disable TLS."
  }

  # Exactly two skips are legitimate, and both are the kubelet: its own metrics
  # and cAdvisor, on the same endpoint, whose serving certificate is signed by a
  # per-node CA the ServiceAccount bundle does not carry. A third occurrence
  # means the cross-cluster hop stopped verifying.
  assert {
    condition     = length(regexall("insecure_skip_verify = true", output.rendered_config)) == 2
    error_message = "Only the two kubelet scrapes may skip verification. A third means the gateway hop stopped verifying."
  }
}

run "credentials_come_from_the_environment" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "sys.env(\"INGEST_PASSWORD\")")
    error_message = "The password must not be templated into the ConfigMap."
  }

  assert {
    condition     = !strcontains(output.rendered_config, "not-a-real-password")
    error_message = "The literal password must never appear in the rendered config."
  }
}

run "discovery_is_scoped_to_the_local_node" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "spec.nodeName=")
    error_message = "Pod discovery must be node-scoped. Without it every DaemonSet instance lists every pod in the cluster and the API server pays for it once per node."
  }

  assert {
    condition     = strcontains(output.rendered_config, "sys.env(\"NODE_NAME\")")
    error_message = "The node name comes from the downward API, not from HOSTNAME — HOSTNAME in a pod is the pod's name."
  }

  assert {
    condition     = length([for e in output.values.alloy.extraEnv : e if e.name == "NODE_NAME"]) == 1
    error_message = "NODE_NAME must be injected from the downward API in the chart values."
  }
}

run "all_three_signals_are_collected" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "otelcol.receiver.otlp")
    error_message = "Traces and app metrics arrive over OTLP from the instrumented workloads."
  }

  assert {
    condition     = strcontains(output.rendered_config, "otelcol.receiver.prometheus")
    error_message = "Infrastructure metrics are scraped as Prometheus and bridged into OTLP."
  }

  assert {
    condition     = strcontains(output.rendered_config, "otelcol.receiver.loki")
    error_message = "Pod logs are tailed as Loki streams and bridged into OTLP."
  }

  assert {
    condition     = strcontains(output.rendered_config, "/metrics/cadvisor")
    error_message = "cAdvisor is a separate scrape path from the kubelet's own metrics; missing it loses all container CPU and memory."
  }
}

run "telemetry_is_stamped_with_its_origin_cluster" {
  command = plan

  assert {
    condition     = length(regexall("obs-platform-prod-workload", output.rendered_config)) >= 3
    error_message = "Every signal must carry its origin cluster, or Grafana cannot show that data came from Cluster A — which is the Proof of Life requirement."
  }
}

run "runs_as_a_daemonset_with_host_logs_mounted" {
  command = plan

  assert {
    condition     = output.values.controller.type == "daemonset"
    error_message = "Node-level logs and kubelet metrics require one instance per node."
  }

  assert {
    condition     = output.values.alloy.mounts.varlog == true
    error_message = "Tailing /var/log/pods requires the host mount."
  }

  assert {
    condition     = output.values.rbac.create == true
    error_message = "The agent needs read-only discovery of pods and nodes; without RBAC nothing is discovered at all."
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
