###############################################################################
# envs/prod — the platform root module
#
#   modules/vpc      x2  -> vpc-workload, vpc-observability
#   modules/security x1  -> peering + cross-VPC OTLP security groups
#   modules/eks      x2  -> eks-workload (Cluster A), eks-observability (B)
#   modules/ecr      x1  -> private registry for images AND OCI Helm charts
#   modules/lgtm-storage x1 -> S3 object stores + IRSA roles for Loki/Mimir/Tempo
#
# Modules never call each other; this file is the only place wiring happens.
#
# Design rationale lives in docs/adr/:
#   0001  two VPCs, one per cluster
#   0002  VPC peering for the telemetry pipeline
#   0003  S3 backend with native state locking
#   0004  EKS cluster security posture
#   0005  private registry and image supply chain
#   0010  cloud-native storage and the IRSA model that reaches it
###############################################################################

###############################################################################
# 1. NETWORKING
###############################################################################

module "vpc_workload" {
  source = "../../modules/vpc"

  name                 = "${var.project}-workload"
  cidr_block           = var.workload_vpc_cidr
  azs                  = local.azs
  private_subnet_cidrs = local.workload_private_subnets
  public_subnet_cidrs  = local.workload_public_subnets

  single_nat_gateway = var.single_nat_gateway
  enable_flow_logs   = true
  cluster_name       = local.workload_cluster_name

  tags = merge(local.common_tags, {
    Tier    = "workload"
    Purpose = "application-fleet"
  })
}

module "vpc_observability" {
  source = "../../modules/vpc"

  name                 = "${var.project}-observability"
  cidr_block           = var.observability_vpc_cidr
  azs                  = local.azs
  private_subnet_cidrs = local.observability_private_subnets
  public_subnet_cidrs  = local.observability_public_subnets

  single_nat_gateway = var.single_nat_gateway
  enable_flow_logs   = true
  cluster_name       = local.observability_cluster_name

  tags = merge(local.common_tags, {
    Tier    = "observability"
    Purpose = "lgtm-stack"
  })
}

###############################################################################
# 2. SECURITY — the peering link and the only ports crossing it
###############################################################################

module "security" {
  source = "../../modules/security"

  name_prefix = "${var.project}-${var.environment}"

  workload_vpc_id                  = module.vpc_workload.vpc_id
  workload_vpc_cidr                = module.vpc_workload.vpc_cidr_block
  workload_private_route_table_ids = module.vpc_workload.private_route_table_ids

  observability_vpc_id                  = module.vpc_observability.vpc_id
  observability_vpc_cidr                = module.vpc_observability.vpc_cidr_block
  observability_private_route_table_ids = module.vpc_observability.private_route_table_ids

  # 4317 = OTLP/gRPC, 4318 = OTLP/HTTP. Nothing else crosses the link.
  otlp_ports = var.otlp_ports

  tags = local.common_tags
}

###############################################################################
# 3. EKS — Cluster A (workload) and Cluster B (observability)
###############################################################################

# Cluster A — Google Online Boutique + the OpenTelemetry Collector agents that
# forward telemetry across the peering link.
module "eks_workload" {
  source = "../../modules/eks"

  cluster_name       = local.workload_cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id = module.vpc_workload.vpc_id
  # Private subnets only.
  private_subnet_ids = module.vpc_workload.private_subnet_ids

  endpoint_private_access = true
  endpoint_public_access  = var.cluster_endpoint_public_access
  public_access_cidrs     = var.cluster_public_access_cidrs

  node_group_name     = "workload"
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  node_labels = {
    "workload-type" = "application"
    "tier"          = "workload"
  }

  # Binds the egress half of the OTLP rules to every node in Cluster A: the
  # collectors may reach the observability VPC on 4317/4318 and nowhere else.
  additional_node_security_group_ids = [module.security.otlp_egress_security_group_id]

  vpc_cni_configuration = local.vpc_cni_configuration
  addon_versions        = var.addon_versions
  access_entries        = local.cluster_access_entries

  tags = merge(local.common_tags, {
    Tier    = "workload"
    Cluster = "A"
  })
}

# Cluster B — Loki, Grafana, Tempo, Mimir. Durable data lives in S3 and is
# reached with IRSA, so this cluster can be rebuilt without data loss.
module "eks_observability" {
  source = "../../modules/eks"

  cluster_name       = local.observability_cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.vpc_observability.vpc_id
  private_subnet_ids = module.vpc_observability.private_subnet_ids

  endpoint_private_access = true
  endpoint_public_access  = var.cluster_endpoint_public_access
  public_access_cidrs     = var.cluster_public_access_cidrs

  node_group_name     = "observability"
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  node_labels = {
    "workload-type" = "observability"
    "tier"          = "observability"
  }

  # Binds the ingress half of the OTLP rules: this is what actually admits
  # cross-VPC telemetry into the Gateway Collector on Cluster B.
  additional_node_security_group_ids = [module.security.otlp_ingress_security_group_id]

  vpc_cni_configuration = local.vpc_cni_configuration
  addon_versions        = var.addon_versions
  access_entries        = local.cluster_access_entries

  tags = merge(local.common_tags, {
    Tier    = "observability"
    Cluster = "B"
  })
}

###############################################################################
# 4. ECR — one registry, consumed by both clusters
#
# Same-account pulls work through AmazonEC2ContainerRegistryReadOnly on the node
# roles, so no repository policy is needed for the clusters themselves; the
# policy below is only rendered when CI push roles are supplied.
###############################################################################

module "ecr" {
  source = "../../modules/ecr"

  repositories = var.ecr_repositories

  image_tag_mutability     = "IMMUTABLE" # non-negotiable production standard
  scan_on_push             = true        # non-negotiable production standard
  enable_enhanced_scanning = var.enable_ecr_enhanced_scanning
  encryption_type          = "KMS"
  force_delete             = var.ecr_force_delete

  push_principal_arns = var.ci_push_role_arns

  tags = merge(local.common_tags, { Component = "supply-chain" })
}

###############################################################################
# 5. LGTM OBJECT STORAGE — S3 + IRSA
#
# Durable storage for the observability stack, and the only credential path to
# it. Three buckets, three roles, no long-lived keys, and no role that can read
# another signal's data.
#
# Deliberately in THIS root module rather than the platform one: buckets and IAM
# are AWS infrastructure with a lifecycle far longer than any Helm release, and
# they must survive `make platform-destroy`. Telemetry data outliving the
# cluster is the entire point of Section 3.
#
#   docs/adr/0010-cloud-native-storage-and-irsa.md
###############################################################################

module "lgtm_storage" {
  source = "../../modules/lgtm-storage"

  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id

  cluster_name       = module.eks_observability.cluster_name
  oidc_provider_arn  = module.eks_observability.oidc_provider_arn
  oidc_provider_host = module.eks_observability.oidc_provider_host

  namespace = var.lgtm_namespace

  tags = merge(local.common_tags, {
    Tier      = "observability"
    Component = "durable-storage"
  })
}
