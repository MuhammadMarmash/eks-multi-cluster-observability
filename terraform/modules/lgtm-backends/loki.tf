###############################################################################
# Loki — logs
#
# SimpleScalable: read, write and backend as separate deployments. The real
# topology, at the smallest counts that still exercise it.
###############################################################################

locals {
  loki_values = {
    deploymentMode = "SimpleScalable"

    loki = {
      image = {
        registry   = var.image_registry
        repository = "mirror/grafana/loki"
        tag        = var.loki_image_tag
      }

      auth_enabled = false # single tenant; the gateway in front is the boundary

      server = { log_level = var.log_level }

      storage = {
        type = "s3"

        # REQUIRED, and absent from the chart's own values.yaml — the helper
        # templates pull it with `dig` and fail the render if it is missing.
        # All three point at the one Loki bucket; Loki separates them by prefix.
        bucketNames = {
          chunks = var.buckets["loki"]
          ruler  = var.buckets["loki"]
          admin  = var.buckets["loki"]
        }

        # No accessKeyId / secretAccessKey. Their absence is what lets the SDK
        # use the IRSA web-identity token.
        s3 = {
          region           = var.aws_region
          endpoint         = local.s3_endpoint
          s3ForcePathStyle = false
          insecure         = false
        }
      }

      # Also EMPTY by default, and Loki will not start without it. v13 + tsdb
      # is the current combination; an older schema silently costs query speed.
      schemaConfig = {
        configs = [
          {
            from         = "2024-04-01"
            store        = "tsdb"
            object_store = "s3"
            schema       = "v13"
            index        = { prefix = "index_", period = "24h" }
          },
        ]
      }

      commonConfig = {
        replication_factor = var.replication_factor
      }

      limits_config = {
        # Alloy bridges pod logs through otelcol.receiver.loki, which can push
        # entries slightly out of order across container restarts.
        reject_old_samples         = true
        reject_old_samples_max_age = "168h"
      }
    }

    serviceAccount = {
      create      = true
      name        = var.service_account_names["loki"]
      annotations = local.service_account_annotations["loki"]
    }

    # --- Topology
    write = {
      replicas = var.ingester_replicas
      # The key is volumeClaimsEnabled. `persistence.enabled` does not exist in
      # this chart and is silently ignored — the StatefulSet keeps its PVC.
      persistence = { volumeClaimsEnabled = false } # WAL only; chunks live in S3
      resources   = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "512Mi" } }
    }

    read = {
      replicas  = 1
      resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "512Mi" } }
    }

    backend = {
      replicas    = 1
      persistence = { volumeClaimsEnabled = false }
      resources   = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "512Mi" } }
    }

    gateway = {
      enabled  = true
      replicas = 1
      image = {
        registry   = var.image_registry
        repository = "mirror/nginxinc/nginx-unprivileged"
        tag        = var.nginx_image_tag
      }
      resources = { requests = { cpu = "50m", memory = "64Mi" }, limits = { memory = "128Mi" } }
    }

    # The ruler sidecar watches ConfigMaps for Loki alerting rules and pulls
    # kiwigrid/k8s-sidecar straight from Docker Hub, which ADR 0005 forbids at
    # deploy time. There are no Loki rules here, so it is a second container per
    # backend pod doing nothing — disabled rather than mirrored.
    sidecar = {
      rules = { enabled = false }
    }

    # chunksCache requests 8192Mi by default — an entire 8 GiB node for a
    # cache, before Loki itself has started.
    chunksCache  = { enabled = var.enable_caches }
    resultsCache = { enabled = var.enable_caches }

    # Unused in this deployment; each is an extra pod on a two-node cluster.
    singleBinary = { replicas = 0 }
    lokiCanary   = { enabled = false }
    test         = { enabled = false }
    monitoring   = { selfMonitoring = { enabled = false }, lokiCanary = { enabled = false } }
    minio        = { enabled = false }
  }
}

resource "helm_release" "loki" {
  name             = "loki"
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  repository       = var.chart_repository
  chart            = "loki"
  version          = var.loki_chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [yamlencode(local.loki_values)]
}
