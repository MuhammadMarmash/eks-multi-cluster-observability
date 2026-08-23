###############################################################################
# Tempo — traces
#
# The SINGLE-BINARY chart, not tempo-distributed. One pod instead of six,
# reclaiming roughly 0.7 vCPU and 2 GiB — which is what makes the stack fit on
# t3.medium nodes at all.
#
# Both Tempo charts are marked `deprecated: true` upstream, so the swap buys
# compute rather than support. appVersion 2.9.0 is current in both.
#
# Trace volume from one Boutique deployment does not need a distributed read
# path; the ingest path is identical either way, and blocks land in the same S3
# bucket through the same IRSA role.
###############################################################################

locals {
  tempo_values = {
    replicas = 1

    tempo = {
      # The chart renders `{{ .Values.tempo.registry }}/{{ .Values.tempo.repository }}`.
      # Putting the full path in repository leaves registry at docker.io and
      # produces docker.io/<account>.dkr.ecr.../tempo.
      registry   = var.image_registry
      repository = "mirror/grafana/tempo"
      tag        = var.tempo_image_tag

      # Generates span metrics and service-graph metrics from spans and
      # remote-writes them to Mimir. Grafana's Service Graph and the RED panels
      # on the Tempo datasource read those from the PROMETHEUS datasource, not
      # from Tempo — so with this off the datasource is wired correctly and the
      # Service Graph is permanently "no data".
      metricsGenerator = {
        enabled = true
        # Mimir's gateway, not its distributor: the gateway injects the
        # X-Scope-OrgID tenant header and Mimir rejects a write without one.
        remoteWriteUrl = var.mimir_push_endpoint
      }

      # Enabling the generator is not enough. Which processors it runs is a
      # per-tenant override, and the default is none.
      overrides = {
        defaults = {
          metrics_generator = {
            processors = ["service-graphs", "span-metrics"]
          }
        }
      }

      storage = {
        trace = {
          # Default is "local" — a node disk. Left alone every trace dies with
          # the pod, and nothing about the deployment looks wrong.
          backend = "s3"
          s3 = {
            bucket   = var.buckets["tempo"]
            region   = var.aws_region
            endpoint = local.s3_endpoint
            # No access_key / secret_key: IRSA supplies the credential, and
            # setting one here would disable it rather than supplement it.
          }
          # Scratch only. Blocks are flushed to S3; this is the staging area.
          wal = { path = "/var/tempo/wal" }
        }
      }

      # The gateway Alloy pushes OTLP here over gRPC.
      receivers = {
        otlp = {
          protocols = {
            grpc = { endpoint = "0.0.0.0:4317" }
            http = { endpoint = "0.0.0.0:4318" }
          }
        }
      }

      resources = {
        requests = { cpu = "100m", memory = "320Mi" }
        limits   = { memory = "640Mi" }
      }
    }

    serviceAccount = {
      create      = true
      name        = var.service_account_names["tempo"]
      annotations = local.service_account_annotations["tempo"]
    }

    # Durable data is in S3. The WAL is scratch and lives in emptyDir: a Tempo
    # restart re-reads from S3, and the window of un-flushed traces is minutes.
    persistence = { enabled = false }

    # A second query UI alongside Grafana would be a pod for nothing.
    tempoQuery = { enabled = false }
  }
}

resource "helm_release" "tempo" {
  name             = "tempo"
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  repository       = var.chart_repository
  chart            = "tempo"
  version          = var.tempo_chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [yamlencode(local.tempo_values)]
}
