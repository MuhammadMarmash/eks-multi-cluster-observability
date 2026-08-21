###############################################################################
# envs/prod-platform — naming and derived values
###############################################################################

locals {
  infra = data.terraform_remote_state.infra.outputs.platform

  workload_cluster_name      = local.infra.clusters.workload.name
  observability_cluster_name = local.infra.clusters.observability.name

  # <account>.dkr.ecr.<region>.amazonaws.com — see modules/ecr's registry_url.
  registry       = local.infra.registry
  chart_registry = "oci://${local.registry}/charts"

  gateway_dns_name = "${var.gateway_hostname}.${var.private_zone_name}"

  # The OIDC issuer without its scheme is the exact string an IRSA trust policy
  # uses as a condition key prefix.
  observability_oidc_host = replace(data.aws_eks_cluster.observability.identity[0].oidc[0].issuer, "https://", "")

  common_tags = {
    Environment = local.infra.environment
    Layer       = "kubernetes-platform"
  }
}
