###############################################################################
# modules/cert-manager
#
# cert-manager exists here for one reason: to issue the telemetry gateway's
# server certificate from a CA whose public half Cluster A can be given, so
# that the agent verifies the gateway for real rather than skipping
# verification.
#
# Why not ACM: a Route 53 *private* zone offers no way to prove domain
# ownership for a public ACM certificate, and ACM Private CA bills roughly
# $400/month against this project's $50 budget.
#   docs/adr/0007-cross-cluster-name-resolution.md
###############################################################################

locals {
  values = {
    crds = {
      # Ship the CRDs with the release rather than installing them out of band.
      # Installed separately, a destroy leaves orphaned Certificates that block
      # namespace deletion.
      enabled = true
      keep    = false
    }

    image           = { repository = "${var.image_registry}/mirror/jetstack/cert-manager-controller" }
    cainjector      = { image = { repository = "${var.image_registry}/mirror/jetstack/cert-manager-cainjector" } }
    webhook         = { image = { repository = "${var.image_registry}/mirror/jetstack/cert-manager-webhook" } }
    startupapicheck = { image = { repository = "${var.image_registry}/mirror/jetstack/cert-manager-startupapicheck" } }

    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = merge(var.labels, {
      "app.kubernetes.io/part-of" = "telemetry-pipeline"
    })
  }
}

resource "helm_release" "this" {
  name             = "cert-manager"
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  repository       = var.chart_repository
  chart            = "cert-manager"
  version          = var.chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true

  # Non-negotiable: the next module reads a Secret that cert-manager has to
  # have issued. Without wait, that read races the webhook coming up and the
  # first apply fails on an empty CA bundle.
  wait    = true
  timeout = 600

  values = [yamlencode(local.values)]
}
