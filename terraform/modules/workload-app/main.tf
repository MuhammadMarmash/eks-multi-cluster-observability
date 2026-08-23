###############################################################################
# modules/workload-app — Cluster A
#
# The instrumented microservices application whose telemetry the platform
# exists to collect. Without it the agent has kubelet metrics and pod logs to
# ship and no traces at all, because nothing emits spans.
#
#   docs/adr/0009-workload-application-source.md
#
# The integration is one environment variable. Every service builds its OTLP
# endpoint from OTEL_COLLECTOR_NAME, so pointing that at the Alloy agent sends
# all three signals into the pipeline. The application knows nothing about
# Cluster B, the peering link, or the gateway.
#
# The chart's own observability stack — Jaeger, Prometheus, Grafana, OpenSearch
# and a bundled collector — is switched off. That stack is the point of the
# upstream demo and entirely redundant here: this platform already has one, in
# another cluster, which is what is being demonstrated.
###############################################################################

locals {
  values = {
    default = {
      # One repository, one tag per component. The chart appends
      # "-<component>" to the tag itself.
      image = {
        repository = "${var.image_registry}/mirror/otel-demo"
      }

      env = [
        {
          name = "OTEL_SERVICE_NAME"
          valueFrom = {
            fieldRef = {
              apiVersion = "v1"
              fieldPath  = "metadata.labels['app.kubernetes.io/component']"
            }
          }
        },
        {
          # THE integration point. Services construct their OTLP endpoint from
          # this hostname; everything else about the pipeline is invisible to
          # them.
          name  = "OTEL_COLLECTOR_NAME"
          value = var.agent_otlp_endpoint
        },
        {
          name  = "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE"
          value = "cumulative"
        },
        {
          name  = "OTEL_RESOURCE_ATTRIBUTES"
          value = "service.version={{ .Chart.AppVersion }}"
        },
      ]
    }

    # The demo's own observability stack. All redundant: the platform this
    # application feeds is the observability stack.
    jaeger                    = { enabled = false }
    prometheus                = { enabled = false }
    grafana                   = { enabled = false }
    opensearch                = { enabled = false }
    "opentelemetry-collector" = { enabled = false }
    "otel-ebpf-profiler"      = { enabled = false }

    components = merge(
      { for c in var.disabled_components : c => { enabled = false } },
      {
        # imageOverride ONLY. Helm REPLACES lists rather than merging them, so
        # setting sidecarContainers here discards the chart's flagd-ui sidecar
        # along with the useDefault block it carries. That surfaces as "nil
        # pointer evaluating interface {}.env", naming neither the list nor the
        # component. The sidecar's image already resolves through default.image.
        flagd = {
          imageOverride = {
            repository = "${var.image_registry}/mirror/open-feature/flagd"
            tag        = var.flagd_image_tag
          }
        }
        "valkey-cart" = {
          imageOverride = {
            repository = "${var.image_registry}/mirror/valkey-io/valkey"
            tag        = var.valkey_image_tag
          }
        }
        "astronomy-db" = {
          imageOverride = {
            repository = "${var.image_registry}/mirror/postgres"
            tag        = var.postgres_image_tag
          }
        }
      },
    )
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/part-of" = "workload-fleet"
    }
  }
}

resource "helm_release" "this" {
  name             = "otel-demo"
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  repository       = var.chart_repository
  chart            = "opentelemetry-demo"
  version          = var.chart_version
  create_namespace = false

  # NOT atomic. Sixteen services starting at once on a two-node cluster will
  # have some pods pending while others schedule, and rolling the whole release
  # back for that would mean never converging. A failed service is visible in
  # the telemetry, which is rather the point.
  atomic          = false
  cleanup_on_fail = false
  wait            = false
  timeout         = 900

  values = [yamlencode(local.values)]
}
