###############################################################################
# modules/grafana — Cluster B
#
# The single pane of glass. Entirely stateless: no PVC, no external database.
# Every datasource and dashboard is provisioned from these values, so a
# destroyed Grafana comes back identical rather than needing a restore.
#
# What that costs: anything a user creates through the UI — an ad-hoc dashboard,
# a saved panel — lives in an ephemeral SQLite file and dies with the pod. That
# is the correct trade for a demo whose dashboards are code, and the wrong one
# for a Grafana people actually author in.
#
# Grafana holds NO AWS credential. It reads through the three backends' HTTP
# APIs; it never touches S3.
#   docs/adr/0010-cloud-native-storage-and-irsa.md
###############################################################################

locals {
  admin_secret = "grafana-admin"

  # Stable UIDs, not chart-generated ones. Provisioned dashboards reference a
  # datasource by UID, so a generated value would break every dashboard on
  # redeploy.
  datasources = [
    {
      name      = "Mimir"
      uid       = "mimir"
      type      = "prometheus"
      access    = "proxy"
      url       = var.datasource_urls["mimir"]
      isDefault = true
      jsonData = {
        # Mimir speaks the Prometheus API; telling Grafana so unlocks the
        # newer query editor and range-query optimisations.
        prometheusType = "Mimir"
        timeInterval   = "60s" # matches the agent's kubelet scrape interval
        httpMethod     = "POST"
        exemplarTraceIdDestinations = [
          { name = "trace_id", datasourceUid = "tempo" },
        ]
      }
    },
    {
      name   = "Loki"
      uid    = "loki"
      type   = "loki"
      access = "proxy"
      url    = var.datasource_urls["loki"]
      jsonData = {
        # Turns a trace ID appearing in a log line into a link to the trace.
        derivedFields = [
          {
            name          = "TraceID"
            matcherRegex  = "trace_id=(\\w+)"
            url           = "$${__value.raw}"
            datasourceUid = "tempo"
          },
        ]
      }
    },
    {
      name   = "Tempo"
      uid    = "tempo"
      type   = "tempo"
      access = "proxy"
      # Single-binary Tempo serves its HTTP API on 3200, not 3100.
      url = var.datasource_urls["tempo"]
      jsonData = {
        # The three links that make one pane of glass rather than three tabs:
        # trace -> logs, trace -> metrics, and the service map.
        tracesToLogsV2 = {
          datasourceUid      = "loki"
          spanStartTimeShift = "-5m"
          spanEndTimeShift   = "5m"
          filterByTraceID    = true
          tags               = [{ key = "service.name", value = "app" }]
        }
        tracesToMetrics = {
          datasourceUid = "mimir"
          tags          = [{ key = "service.name", value = "service" }]
        }
        serviceMap = { datasourceUid = "mimir" }
        nodeGraph  = { enabled = true }
        lokiSearch = { datasourceUid = "loki" }
      }
    },
  ]

  values = {
    # No PVC and no external database. SQLite in the container filesystem.
    persistence = { enabled = false }

    replicas = 1

    # registry and repository are concatenated by the chart as
    # "<registry>/<repository>". An empty registry yields a LEADING SLASH and an
    # invalid image reference, so the two halves are passed separately.
    image = {
      registry   = var.image_registry
      repository = var.image_repository
      tag        = var.image_tag
    }

    serviceAccount = {
      create = true
      name   = var.service_account_name
      # No eks.amazonaws.com/role-arn. See the variable's description.
    }

    # Only the dashboard/datasource sidecars need cluster RBAC, and everything
    # here is provisioned from values instead.
    rbac = { create = false }

    admin = {
      existingSecret = local.admin_secret
      userKey        = "admin-user"
      passwordKey    = "admin-password"
    }

    # Provisioning. This is the block that wires Grafana to the three backends.
    datasources = {
      "datasources.yaml" = {
        apiVersion  = 1
        datasources = local.datasources
      }
    }

    "grafana.ini" = {
      analytics = {
        # The cluster has no public egress path worth spending on a version
        # check, and a blocked check adds startup latency.
        reporting_enabled = false
        check_for_updates = false
      }
      users = { allow_sign_up = false }
      # Anonymous access stays off. The gateway in front of the cluster is not
      # a substitute for authenticating the console itself.
      "auth.anonymous" = { enabled = false }
    }

    # ClusterIP. Reached with `kubectl port-forward` — a second load balancer
    # for a demo console would double this layer's hourly cost.
    service = { type = "ClusterIP", port = 80 }

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }

    # A bats container pulled from Docker Hub, run once, for a smoke test we do
    # not use. It is also an image ADR 0005 would require mirroring.
    testFramework = { enabled = false }
  }
}

resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "observability-platform"
    }
  }
}

# Generated, never committed. Lands in Terraform state, which is S3-encrypted
# per ADR 0003. `terraform output -raw grafana_admin_password` retrieves it.
resource "random_password" "admin" {
  length  = 24
  special = false # copy-pasteable into a browser login without escaping
}

resource "kubernetes_secret_v1" "admin" {
  metadata {
    name      = local.admin_secret
    namespace = var.namespace
  }

  data = {
    "admin-user"     = var.admin_user
    "admin-password" = random_password.admin.result
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.this]
}

resource "helm_release" "this" {
  name             = "grafana"
  namespace        = var.namespace
  repository       = var.chart_repository
  chart            = "grafana"
  version          = var.chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [yamlencode(local.values)]

  depends_on = [kubernetes_secret_v1.admin]
}
