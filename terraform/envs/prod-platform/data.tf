###############################################################################
# envs/prod-platform — what this layer reads from the layer below
#
# The infrastructure state is the contract. Cluster CA data and the OIDC issuer
# are looked up live rather than read from state, so envs/prod needs no new
# outputs and the values cannot go stale between applies.
###############################################################################

data "terraform_remote_state" "infra" {
  backend = "s3"

  config = {
    bucket = var.infra_state_bucket
    key    = var.infra_state_key
    region = var.aws_region
  }
}

data "aws_eks_cluster" "workload" {
  name = local.workload_cluster_name
}

data "aws_eks_cluster" "observability" {
  name = local.observability_cluster_name
}

# Short-lived registry credential, re-read on every plan. The charts live in
# ECR rather than on a public chart repository (ADR 0005).
data "aws_ecr_authorization_token" "this" {}
