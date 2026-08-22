###############################################################################
# modules/aws-lb-controller
#
# The AWS Load Balancer Controller, so that a Service of type LoadBalancer
# becomes an NLB with `ip` targets and a security group we choose, rather than
# the Classic LB the legacy in-tree cloud provider would create.
#
# The telemetry gateway's internal NLB depends on all three of those
# capabilities:
#   docs/adr/0007-cross-cluster-name-resolution.md
#
# enableCertManager is false on purpose. The chart can self-sign its admission
# webhook certificate, and making it wait on cert-manager creates a deploy
# ordering cycle for no security gain — the webhook is cluster-internal.
###############################################################################

locals {
  service_account_name = "aws-load-balancer-controller"

  # The vendored upstream policy is kept pretty-printed so a version bump shows
  # a readable diff. IAM caps an inline role policy at 10,240 characters and the
  # document is already ~8.9 KB pretty, so it is round-tripped through
  # jsondecode/jsonencode to strip the whitespace before it is sent.
  inline_policy_json = jsonencode(jsondecode(file("${path.module}/iam-policy.json")))

  values = {
    clusterName = var.cluster_name
    region      = var.region
    vpcId       = var.vpc_id

    replicaCount = var.replicas

    image = {
      repository = var.image_repository
      tag        = var.image_tag
    }

    serviceAccount = {
      create = true
      name   = local.service_account_name
      annotations = {
        "eks.amazonaws.com/role-arn" = module.irsa.role_arn
      }
    }

    enableCertManager = false

    # OFF, and this is a correctness fix rather than a preference.
    #
    # The Service mutator webhook intercepts every Service CREATE in the WHOLE
    # cluster, with failurePolicy: Fail. While the controller has no ready
    # endpoints, nothing anywhere can create a Service — cert-manager, Mimir,
    # Loki and Grafana all fail with "no endpoints available for service
    # aws-load-balancer-webhook-service", which names the victim rather than
    # the cause.
    #
    # Its only job is to stamp loadBalancerClass onto Services of type
    # LoadBalancer that do NOT carry the aws-load-balancer-type annotation. The
    # one such Service in this platform, the telemetry gateway's NLB, sets that
    # annotation explicitly, so the webhook has nothing to do here and exists
    # purely as a cluster-wide single point of failure.
    enableServiceMutatorWebhook = false

    # The controller is cluster infrastructure: it must keep running while the
    # nodes it manages are under pressure.
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
  }
}

module "irsa" {
  source = "../irsa"

  role_name          = "role-${var.cluster_name}-alb-controller"
  oidc_provider_arn  = var.oidc_provider_arn
  oidc_provider_host = var.oidc_provider_host
  namespace          = var.namespace
  service_account    = local.service_account_name
  description        = "AWS Load Balancer Controller for ${var.cluster_name}"
  inline_policy_json = local.inline_policy_json

  tags = var.tags
}

resource "helm_release" "this" {
  name             = "aws-load-balancer-controller"
  namespace        = var.namespace
  repository       = var.chart_repository
  chart            = "aws-load-balancer-controller"
  version          = var.chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [yamlencode(local.values)]
}
