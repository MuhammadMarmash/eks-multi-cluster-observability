###############################################################################
# modules/telemetry-gateway — Cluster B
#
# The far end of the cross-cluster pipeline. An internal NLB accepts 4317/4318
# from the workload VPC and passes TCP straight through to Alloy, which
# terminates TLS and basic auth and fans out locally.
#
#   docs/adr/0002-cross-vpc-telemetry-transport.md   why peering, and the
#                                                    three-layer security model
#   docs/adr/0007-cross-cluster-name-resolution.md   why an NLB plus a private
#                                                    zone, and not CoreDNS
###############################################################################

locals {
  tags = merge(
    var.tags,
    {
      "Module"    = "telemetry-gateway"
      "ManagedBy" = "terraform"
    },
  )

  release_name       = "alloy-gateway"
  credentials_secret = "telemetry-ingest-credentials"
  tls_secret         = "telemetry-gateway-tls"
  ca_secret          = "telemetry-ca-key-pair"
  ingest_username    = "alloy-workload"

  tls_mount_path = "/etc/alloy/tls"

  # Selector labels the Alloy chart puts on its pods. The NLB Service below
  # targets these directly rather than going through the chart's own Service,
  # so every load balancer annotation stays visible in this file.
  pod_selector = {
    "app.kubernetes.io/name"     = "alloy"
    "app.kubernetes.io/instance" = local.release_name
  }

  config = templatefile("${path.module}/config.alloy.tftpl", {
    log_level      = var.log_level
    memory_limit   = var.memory_limit
    tls_cert_path  = "${local.tls_mount_path}/tls.crt"
    tls_key_path   = "${local.tls_mount_path}/tls.key"
    lgtm_enabled   = var.lgtm_enabled
    mimir_endpoint = var.mimir_endpoint
    loki_endpoint  = var.loki_endpoint
    tempo_endpoint = var.tempo_endpoint
  })

  values = {
    alloy = {
      configMap = {
        create  = true
        content = local.config
      }

      # otelcol.exporter.debug is an experimental component and Alloy REFUSES
      # TO START if the stability level does not admit it. The debug sink only
      # exists until the LGTM stack lands, so the gate is raised only while it
      # is in use; with real backends every component here is
      # generally-available and the default applies again.
      stabilityLevel = var.lgtm_enabled ? "generally-available" : "experimental"

      extraEnv = [
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
        extra = [
          { name = "tls", mountPath = local.tls_mount_path, readOnly = true },
        ]
      }

      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
    }

    controller = {
      type     = "deployment"
      replicas = var.replicas

      # Without this, a node drain can evict BOTH replicas at once and ingest
      # goes to zero. The agent on Cluster A retries for five minutes and then
      # drops telemetry on the floor, so an unprotected gateway is the one thing
      # that turns a routine node roll into data loss.
      #   docs/runbooks/day-2-ops.md
      podDisruptionBudget = {
        enabled        = var.replicas > 1
        maxUnavailable = 1
      }

      # Required, not preferred. `preferred` would let the scheduler co-locate
      # both replicas under pressure, which is precisely the state a node roll
      # creates — so the soft version fails exactly when it is needed.
      #
      # Safe at these numbers: two replicas across three nodes still schedule
      # when one node is draining. Raising `replicas` above the node count would
      # leave the surplus Pending, which is why the PDB is gated on replicas > 1
      # rather than assumed.
      affinity = {
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [
            {
              topologyKey = "kubernetes.io/hostname"
              labelSelector = {
                matchLabels = local.pod_selector
              }
            },
          ]
        }
      }

      volumes = {
        extra = [
          { name = "tls", secret = { secretName = local.tls_secret } },
        ]
      }
    }

    # The gateway receives and forwards. It never reads the Kubernetes API, so
    # it gets no access to it.
    rbac = {
      create = false
    }

    # Our own Service below carries the load balancer annotations.
    service = {
      enabled = false
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

###############################################################################
# Ingest credential
#
# Generated here, never committed. It does land in Terraform state, which is
# S3-encrypted per ADR 0003. Changing the keeper rotates it on both clusters in
# a single apply.
###############################################################################

resource "random_password" "ingest" {
  length  = 40
  special = false # keeps it safe in a URL, a header and a shell without quoting

  keepers = {
    cluster = var.cluster_name
  }
}

resource "kubernetes_secret_v1" "credentials" {
  metadata {
    name      = local.credentials_secret
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    username = local.ingest_username
    password = random_password.ingest.result
  }

  type = "Opaque"
}

###############################################################################
# Certificates
###############################################################################

resource "helm_release" "certs" {
  name             = "telemetry-certs"
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  chart            = var.certs_chart_path
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 300

  values = [yamlencode({
    certManagerNamespace = var.cert_manager_namespace
    gatewayNamespace     = kubernetes_namespace_v1.this.metadata[0].name
    gatewayDnsName       = var.gateway_dns_name
    caSecretName         = local.ca_secret
    gatewaySecretName    = local.tls_secret
  })]
}

# helm_release.wait returns when the custom resources are accepted, not when
# cert-manager has finished issuing. Reading the CA secret immediately after is
# a race; this is the slack that avoids it.
resource "time_sleep" "wait_for_issuance" {
  depends_on      = [helm_release.certs]
  create_duration = var.cert_wait_duration
}

data "kubernetes_secret_v1" "ca" {
  depends_on = [time_sleep.wait_for_issuance]

  metadata {
    name      = local.ca_secret
    namespace = var.cert_manager_namespace
  }
}

###############################################################################
# Gateway
###############################################################################

resource "helm_release" "gateway" {
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
    time_sleep.wait_for_issuance,
  ]
}

###############################################################################
# Internal NLB
#
# Built here rather than through the chart's own Service so that every
# annotation that matters to the security model is visible in one place.
###############################################################################

resource "kubernetes_service_v1" "gateway" {
  metadata {
    name      = "telemetry-gateway"
    namespace = kubernetes_namespace_v1.this.metadata[0].name

    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internal"
      "service.beta.kubernetes.io/aws-load-balancer-subnets"         = join(",", var.nlb_subnet_ids)
      "service.beta.kubernetes.io/aws-load-balancer-security-groups" = join(",", var.nlb_security_group_ids)

      # Let the controller open the node-side rules from the load balancer's
      # group, so pod traffic is admitted without widening anything by hand.
      "service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules" = "true"

      # TCP, not TLS: termination belongs at the pod, per ADR 0002.
      "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "tcp"
    }
  }

  spec {
    type     = "LoadBalancer"
    selector = local.pod_selector

    port {
      name        = "otlp-grpc"
      port        = 4317
      target_port = 4317
      protocol    = "TCP"
    }

    port {
      name        = "otlp-http"
      port        = 4318
      target_port = 4318
      protocol    = "TCP"
    }
  }

  # The controller has to be running to reconcile this into an NLB, and the
  # pods have to exist for the target group to have anything in it.
  depends_on = [helm_release.gateway]

  timeouts {
    create = "15m"
  }
}

###############################################################################
# The name
#
# A CNAME rather than an alias: the NLB is created by Kubernetes, so its zone
# ID is not a Terraform-known value here, and AWS keeps its own name resolving
# to current private addresses regardless.
###############################################################################

resource "aws_route53_record" "gateway" {
  zone_id = var.route53_zone_id
  name    = var.gateway_dns_name
  type    = "CNAME"
  ttl     = 60
  records = [kubernetes_service_v1.gateway.status[0].load_balancer[0].ingress[0].hostname]
}
