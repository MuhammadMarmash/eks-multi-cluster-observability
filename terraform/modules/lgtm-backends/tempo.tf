###############################################################################
# Tempo — traces
#
# tempo-distributed. Receives OTLP from the gateway Alloy and writes blocks
# straight to S3.
###############################################################################

locals {
  tempo_values = {
    tempo = {
      image = {
        registry   = var.image_registry
        repository = "mirror/grafana/tempo"
        tag        = var.tempo_image_tag
      }
      logLevel = var.log_level
    }

    serviceAccount = {
      create      = true
      name        = var.service_account_names["tempo"]
      annotations = local.service_account_annotations["tempo"]
    }

    storage = {
      trace = {
        # Default is "local" — a node disk. Left alone, every trace is lost
        # with the pod and nothing about the deployment looks wrong.
        backend = "s3"
        s3 = {
          bucket   = var.buckets["tempo"]
          region   = var.aws_region
          endpoint = local.s3_endpoint
          # No access_key / secret_key: IRSA supplies the credential.
        }
      }
    }

    # --- Topology
    distributor = {
      replicas  = 1
      resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "512Mi" } }

      # The gateway Alloy in the telemetry namespace pushes OTLP here.
      config = {
        log_received_spans = { enabled = false }
      }
    }

    ingester = {
      replicas    = var.ingester_replicas
      persistence = { enabled = false }
      config = {
        replication_factor = var.replication_factor
      }
      resources = { requests = { cpu = "150m", memory = "512Mi" }, limits = { memory = "1Gi" } }
    }

    querier = {
      replicas  = 1
      resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "512Mi" } }
    }

    queryFrontend = {
      replicas  = 1
      resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "512Mi" } }
    }

    compactor = {
      replicas  = 1
      resources = { requests = { cpu = "100m", memory = "512Mi" }, limits = { memory = "1Gi" } }
    }

    # memcached ships ENABLED in this chart.
    memcached = { enabled = var.enable_caches }

    # The gateway Alloy already fronts ingest; a second nginx adds a pod and a
    # hop for nothing.
    gateway          = { enabled = false }
    metricsGenerator = { enabled = false }
    metaMonitoring   = { grafanaAgent = { enabled = false } }
    minio            = { enabled = false }
  }
}

resource "helm_release" "tempo" {
  name             = "tempo"
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  repository       = var.chart_repository
  chart            = "tempo-distributed"
  version          = var.tempo_chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [yamlencode(local.tempo_values)]
}
