###############################################################################
# envs/prod — naming and subnet plan
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  workload_cluster_name      = "${var.project}-${var.environment}-workload"
  observability_cluster_name = "${var.project}-${var.environment}-observability"

  ###########################################################################
  # Subnet plan
  #
  #   private: /20 per AZ  -> 4,091 usable IPs each
  #   public : /24 per AZ  ->   251 usable IPs each
  #
  # The asymmetry is intentional. Public subnets hold nothing but NAT gateways
  # and load balancer ENIs, so a /24 is generous. Private subnets hold every
  # node AND every Pod ENI — with the VPC CNI, Pod count is subnet-IP-bound, so
  # they are sized an order of magnitude larger and left room to grow into
  # prefix delegation (/28 blocks reserved per ENI).
  #
  # Example for 10.0.0.0/16:
  #   private -> 10.0.0.0/20, 10.0.16.0/20, 10.0.32.0/20
  #   public  -> 10.0.100.0/24, 10.0.101.0/24, 10.0.102.0/24
  ###########################################################################
  workload_private_subnets = [for i in range(var.az_count) : cidrsubnet(var.workload_vpc_cidr, 4, i)]
  workload_public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.workload_vpc_cidr, 8, 100 + i)]

  observability_private_subnets = [for i in range(var.az_count) : cidrsubnet(var.observability_vpc_cidr, 4, i)]
  observability_public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.observability_vpc_cidr, 8, 100 + i)]

  # Prefix delegation raises Pods-per-node well above the default secondary-IP
  # limit (e.g. a t3.large goes from 35 to 110 Pods).
  vpc_cni_configuration = var.enable_prefix_delegation ? jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"

      # Network policy support, so the LGTM namespaces can be locked down with
      # NetworkPolicies rather than relying on security groups alone.
      ENABLE_NETWORK_POLICY = "true"
    }
  }) : null

  # Cluster-admin access entries, applied identically to both clusters.
  cluster_access_entries = {
    for arn in var.cluster_admin_role_arns : "admin-${basename(arn)}" => {
      principal_arn = arn
      policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
      access_scope  = { type = "cluster" }
    }
  }

  common_tags = {
    Project     = var.project
    Environment = var.environment
  }
}
