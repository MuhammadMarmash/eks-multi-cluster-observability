###############################################################################
# modules/metrics-server
#
# Serves the resource metrics API — `kubectl top`, and the CPU and memory
# signals every HorizontalPodAutoscaler reads.
#
# Without it an HPA does not degrade, it simply never functions: it reports
# `<unknown>` for its target forever and never scales. That made the autoscaling
# half of docs/runbooks/day-2-ops.md theoretical rather than actionable, which
# is why this exists.
#
# Deployed to BOTH clusters. Cluster A needs it for the Boutique; Cluster B
# needs it for the Mimir ingester work the runbook describes.
###############################################################################

locals {
  values = {
    replicas = var.replicas

    image = {
      # The chart joins registry and repository. An empty registry yields a
      # leading slash and an unpullable reference.
      repository = "${var.image_registry}/${var.image_repository}"
      tag        = var.image_tag
    }

    args = [
      # EKS kubelets serve a certificate signed by a per-node CA that the
      # cluster CA bundle does not contain, so the scrape cannot be verified
      # against it. This is the same constraint the Alloy agent works around
      # for its kubelet scrape, and it is a hop to the node's own address on
      # its own network — unrelated to any cross-cluster path.
      "--kubelet-insecure-tls",
    ]

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }

    # Single replica, so a PDB would only ever block a drain.
    podDisruptionBudget = { enabled = false }
  }
}

resource "helm_release" "this" {
  name       = "metrics-server"
  namespace  = var.namespace
  repository = var.chart_repository
  chart      = "metrics-server"
  version    = var.chart_version

  # kube-system is created by Kubernetes itself.
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 300

  values = [yamlencode(local.values)]
}
