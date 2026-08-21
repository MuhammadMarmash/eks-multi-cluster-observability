###############################################################################
# Mimir — metrics
#
# mimir-distributed, scaled down. Read/write paths stay separate so the
# architecture is the real one, but every replica count is at the floor.
###############################################################################

locals {
  mimir_values = {
    # MinIO ships ENABLED in this chart. Left alone it becomes the durable
    # store, backed by a PVC, and nothing looks wrong until the pod moves.
    minio = { enabled = false }

    image = {
      repository = "${var.image_registry}/mirror/grafana/mimir"
      tag        = var.mimir_image_tag
    }

    serviceAccount = {
      create      = true
      name        = var.service_account_names["mimir"]
      annotations = local.service_account_annotations["mimir"]
    }

    mimir = {
      structuredConfig = {
        # No access_key_id / secret_access_key anywhere. Their absence is what
        # sends the SDK to the IRSA web-identity token.
        common = {
          storage = {
            backend = "s3"
            s3 = {
              bucket_name = var.buckets["mimir"]
              region      = var.aws_region
              endpoint    = local.s3_endpoint
            }
          }
        }

        blocks_storage = {
          backend = "s3"
          s3      = { bucket_name = var.buckets["mimir"] }
          # Local scratch only — TSDB head and shipped-block staging. Rebuilt
          # from S3 on restart; nothing durable lives here.
          tsdb         = { dir = "/data/tsdb" }
          bucket_store = { sync_dir = "/data/tsdb-sync" }
        }

        # Default is 3, which also sets the minimum ingester count. Left alone,
        # the ring never becomes healthy on a scaled-down cluster and every
        # write is refused.
        ingester = {
          ring = { replication_factor = var.replication_factor }
        }

        store_gateway = {
          sharding_ring = { replication_factor = var.replication_factor }
        }

        server = { log_level = var.log_level }

        limits = {
          # Alloy stamps a `cluster` resource attribute on everything, which
          # becomes a label. Headroom for it and for the Boutique's own labels.
          max_label_names_per_series = 40
        }
      }
    }

    # --- Topology. Every count is the floor that still exercises the real
    # --- read/write split.
    distributor = {
      replicas  = 1
      resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "512Mi" } }
    }

    ingester = {
      replicas = var.ingester_replicas
      # Stateless by instruction: the WAL goes to emptyDir. The trade-off is
      # real — a restarting ingester loses samples not yet flushed to a block.
      # See the module's README note and ADR 0010.
      persistentVolume     = { enabled = false }
      zoneAwareReplication = { enabled = false }
      resources            = { requests = { cpu = "200m", memory = "512Mi" }, limits = { memory = "1Gi" } }
    }

    querier = {
      replicas  = 1
      resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "512Mi" } }
    }

    query_frontend = {
      replicas  = 1
      resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "512Mi" } }
    }

    query_scheduler = {
      replicas  = 1
      resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "256Mi" } }
    }

    store_gateway = {
      replicas             = 1
      persistentVolume     = { enabled = false }
      zoneAwareReplication = { enabled = false }
      resources            = { requests = { cpu = "100m", memory = "512Mi" }, limits = { memory = "1Gi" } }
    }

    compactor = {
      replicas         = 1
      persistentVolume = { enabled = false }
      resources        = { requests = { cpu = "100m", memory = "512Mi" }, limits = { memory = "1Gi" } }
    }

    gateway = {
      replicas = 1
      nginx = {
        image = {
          registry   = var.image_registry
          repository = "mirror/nginxinc/nginx-unprivileged"
          tag        = var.nginx_image_tag
        }
      }
      resources = { requests = { cpu = "50m", memory = "64Mi" }, limits = { memory = "128Mi" } }
    }

    # Required by the chart to roll StatefulSets safely; it is not optional.
    rollout_operator = {
      enabled = true
      image = {
        repository = "${var.image_registry}/mirror/grafana/rollout-operator"
        tag        = var.rollout_operator_image_tag
      }
      resources = { requests = { cpu = "50m", memory = "64Mi" }, limits = { memory = "128Mi" } }
    }

    # Both write to the SAME Mimir bucket under their own prefixes, so turning
    # them on needs capacity, not a new bucket or IAM change.
    ruler        = { enabled = var.enable_mimir_ruler_and_alertmanager, replicas = 1 }
    alertmanager = { enabled = var.enable_mimir_ruler_and_alertmanager, replicas = 1, persistentVolume = { enabled = false } }

    # Chart 6.2.0 ships an experimental Kafka-backed ingest path ENABLED, which
    # renders a whole Kafka StatefulSet with a 5Gi PVC. Nothing here uses it.
    kafka = { enabled = false }

    overrides_exporter = { enabled = false }
    metaMonitoring     = { grafanaAgent = { enabled = false } }
    smoke_test         = { enabled = false }
    continuous_test    = { enabled = false }
  }
}

resource "helm_release" "mimir" {
  name             = "mimir"
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  repository       = var.chart_repository
  chart            = "mimir-distributed"
  version          = var.mimir_chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [yamlencode(local.mimir_values)]
}
