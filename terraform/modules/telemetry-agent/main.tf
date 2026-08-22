###############################################################################
# modules/telemetry-agent — Cluster A
#
# One Alloy per node. Collects OTLP from the instrumented workloads, scrapes
# the local kubelet and cAdvisor, tails this node's pod logs, converts all
# three to OTLP, and ships them on a single authenticated connection to the
# gateway in Cluster B.
#
#   docs/adr/0006-telemetry-agent-selection.md   why Alloy, not the upstream
#                                                collector plus two more agents
#   docs/adr/0002-cross-vpc-telemetry-transport.md
###############################################################################

locals {
  release_name       = "alloy-agent"
  credentials_secret = "telemetry-gateway-credentials"
  ca_secret          = "telemetry-gateway-ca"
  ca_mount_path      = "/etc/alloy/certs"

  config = templatefile("${path.module}/config.alloy.tftpl", {
    cluster_name     = var.cluster_name
    log_level        = var.log_level
    memory_limit     = var.memory_limit
    scrape_interval  = var.scrape_interval
    gateway_endpoint = var.gateway_endpoint
    ca_file_path     = "${local.ca_mount_path}/ca.crt"
  })

  values = {
    alloy = {
      configMap = {
        create  = true
        content = local.config
      }

      # Every component in this pipeline is generally-available. If a future
      # change needs an experimental one, raising this is a deliberate act,
      # not a default that quietly admits anything.
      stabilityLevel = "generally-available"

      extraEnv = [
        {
          # HOSTNAME inside a pod is the POD's name. Node-scoped discovery
          # needs the node's name, which only the downward API can supply.
          name = "NODE_NAME"
          valueFrom = {
            fieldRef = { fieldPath = "spec.nodeName" }
          }
        },
        {
          name = "INGEST_USERNAME"
          valueFrom = {
            secretKeyRef = { name = local.credentials_secret, key = "username" }
          }
        },
        {
          name = "INGEST_PASSWORD"
          valueFrom = {
            secretKeyRef = { name = local.credentials_secret, key = "password" }
          }
        },
      ]

      mounts = {
        # Tailing /var/log/pods needs the host's log directory.
        varlog = true

        extra = [
          { name = "gateway-ca", mountPath = local.ca_mount_path, readOnly = true },
        ]
      }

      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }

    controller = {
      # One per node: node-level logs and kubelet metrics cannot be collected
      # any other way.
      type = "daemonset"

      volumes = {
        extra = [
          { name = "gateway-ca", secret = { secretName = local.ca_secret } },
        ]
      }

      # Telemetry collection must survive on nodes that are cordoned or
      # carrying a taint, or the record of what went wrong there is lost.
      tolerations = [
        { operator = "Exists" },
      ]
    }

    # Read-only discovery of pods, nodes and namespaces, and access to the
    # kubelet metrics endpoints. Nothing writable.
    rbac = {
      create = true
    }

    # registry and repository are concatenated by the chart as
    # "<registry>/<repository>". An empty registry yields a LEADING SLASH and an
    # invalid image reference, so the two halves are passed separately.
    image = {
      registry   = var.image_registry
      repository = var.image_repository
      tag        = var.image_tag
    }

    # The chart's config-reloader sidecar pulls from quay.io, which ADR 0005
    # forbids at deploy time. It exists to signal a reload when the ConfigMap
    # changes; here the config only ever changes through a Helm release, which
    # rolls the pods anyway, so the sidecar buys nothing and costs an
    # unmirrored image plus 50Mi per pod.
    configReloader = { enabled = false }
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "telemetry-pipeline"
    }
  }
}

# The credential the gateway will check. Generated in the gateway module and
# handed here, so there is exactly one source of truth for it.
resource "kubernetes_secret_v1" "credentials" {
  metadata {
    name      = local.credentials_secret
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    username = var.ingest_username
    password = var.ingest_password
  }

  type = "Opaque"
}

# The CA that signed the gateway's certificate. Public material, which is why
# it travels as a plain Secret rather than through a secret store.
resource "kubernetes_secret_v1" "gateway_ca" {
  metadata {
    name      = local.ca_secret
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    "ca.crt" = var.gateway_ca_pem
  }

  type = "Opaque"
}

resource "helm_release" "this" {
  name             = local.release_name
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  repository       = var.chart_repository
  chart            = "alloy"
  version          = var.chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [yamlencode(local.values)]

  depends_on = [
    kubernetes_secret_v1.credentials,
    kubernetes_secret_v1.gateway_ca,
  ]
}
