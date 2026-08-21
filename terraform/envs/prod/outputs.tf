###############################################################################
# envs/prod — outputs
#
# Everything the Helm/GitOps layer and the CI pipeline need to take over from
# here. `terraform output -json platform` gives a single machine-readable blob.
###############################################################################

# --- Networking ----------------------------------------------------------------

output "workload_vpc_id" {
  description = "ID of vpc-workload (Cluster A)."
  value       = module.vpc_workload.vpc_id
}

output "observability_vpc_id" {
  description = "ID of vpc-observability (Cluster B)."
  value       = module.vpc_observability.vpc_id
}

output "workload_vpc_cidr" {
  description = "CIDR of vpc-workload."
  value       = module.vpc_workload.vpc_cidr_block
}

output "observability_vpc_cidr" {
  description = "CIDR of vpc-observability."
  value       = module.vpc_observability.vpc_cidr_block
}

output "workload_private_subnet_ids" {
  description = "Private subnets hosting the Cluster A nodes."
  value       = module.vpc_workload.private_subnet_ids
}

output "observability_private_subnet_ids" {
  description = "Private subnets hosting the Cluster B nodes."
  value       = module.vpc_observability.private_subnet_ids
}

output "peering_connection_id" {
  description = "VPC peering connection carrying the telemetry pipeline."
  value       = module.security.peering_connection_id
}

output "otlp_security_group_ids" {
  description = "Security groups implementing the cross-VPC OTLP path."
  value = {
    workload_egress       = module.security.otlp_egress_security_group_id
    observability_ingress = module.security.otlp_ingress_security_group_id
  }
}

# --- Clusters --------------------------------------------------------------------

output "workload_cluster" {
  description = "Cluster A connection details."
  value = {
    name              = module.eks_workload.cluster_name
    endpoint          = module.eks_workload.cluster_endpoint
    version           = module.eks_workload.cluster_version
    oidc_provider_arn = module.eks_workload.oidc_provider_arn
    oidc_provider_url = module.eks_workload.oidc_provider_url
    node_role_arn     = module.eks_workload.node_iam_role_arn
    kubeconfig        = module.eks_workload.kubeconfig_command
  }
}

output "observability_cluster" {
  description = "Cluster B connection details."
  value = {
    name              = module.eks_observability.cluster_name
    endpoint          = module.eks_observability.cluster_endpoint
    version           = module.eks_observability.cluster_version
    oidc_provider_arn = module.eks_observability.oidc_provider_arn
    oidc_provider_url = module.eks_observability.oidc_provider_url
    node_role_arn     = module.eks_observability.node_iam_role_arn
    kubeconfig        = module.eks_observability.kubeconfig_command
  }
}

# The OIDC provider ARNs are the single most-referenced outputs downstream:
# every LGTM component's IRSA role (Loki, Mimir, Tempo, Grafana -> S3) is built
# from the observability cluster's provider.
output "observability_oidc_provider_arn" {
  description = "OIDC provider ARN for Cluster B. Required to build the IRSA roles that let Loki/Mimir/Tempo reach S3 without static keys."
  value       = module.eks_observability.oidc_provider_arn
}

output "workload_oidc_provider_arn" {
  description = "OIDC provider ARN for Cluster A."
  value       = module.eks_workload.oidc_provider_arn
}

output "cluster_addon_versions" {
  description = "Installed add-on versions per cluster — the reference point for the Day-2 upgrade runbook."
  value = {
    workload      = module.eks_workload.addon_versions
    observability = module.eks_observability.addon_versions
  }
}

# --- Registry ---------------------------------------------------------------------

output "ecr_repository_urls" {
  description = "ECR repository URIs keyed by repository name."
  value       = module.ecr.repository_urls
}

output "ecr_registry_url" {
  description = "Base ECR registry URL for docker/helm login."
  value       = module.ecr.registry_url
}

output "ecr_login_command" {
  description = "Command that authenticates Docker and Helm against the registry."
  value       = module.ecr.docker_login_command
}

# --- LGTM durable storage -----------------------------------------------------------

output "lgtm_bucket_names" {
  description = "S3 bucket name per component. Goes into each chart's object-storage config."
  value       = module.lgtm_storage.bucket_names
}

output "lgtm_irsa_role_arns" {
  description = "IRSA role ARN per component. Annotate each ServiceAccount with eks.amazonaws.com/role-arn set to this."
  value       = module.lgtm_storage.irsa_role_arns
}

# The mapping stage 2's Helm values need, in one place. The ServiceAccount names
# are pinned in the trust policies, so the charts must be told to use them
# rather than their own release-derived defaults.
output "lgtm_service_account_to_role" {
  description = "namespace/ServiceAccount -> IAM role ARN. Every entry must be reproduced exactly in the LGTM Helm values."
  value       = module.lgtm_storage.service_account_to_role
}

output "lgtm_namespace" {
  description = "Namespace the LGTM stack must run in. Pinned in every IRSA trust policy."
  value       = module.lgtm_storage.namespace
}

# --- Aggregate ---------------------------------------------------------------------

output "platform" {
  description = "Single machine-readable summary consumed by CI and the Helm layer."
  value = {
    region      = var.aws_region
    account_id  = data.aws_caller_identity.current.account_id
    environment = var.environment

    clusters = {
      workload = {
        name              = module.eks_workload.cluster_name
        endpoint          = module.eks_workload.cluster_endpoint
        oidc_provider_arn = module.eks_workload.oidc_provider_arn
        vpc_id            = module.vpc_workload.vpc_id
        vpc_cidr          = module.vpc_workload.vpc_cidr_block
      }
      observability = {
        name              = module.eks_observability.cluster_name
        endpoint          = module.eks_observability.cluster_endpoint
        oidc_provider_arn = module.eks_observability.oidc_provider_arn
        vpc_id            = module.vpc_observability.vpc_id
        vpc_cidr          = module.vpc_observability.vpc_cidr_block
      }
    }

    telemetry = {
      peering_connection_id = module.security.peering_connection_id
      otlp_ports            = module.security.otlp_ports
    }

    storage = {
      namespace               = module.lgtm_storage.namespace
      buckets                 = module.lgtm_storage.bucket_names
      irsa_role_arns          = module.lgtm_storage.irsa_role_arns
      service_account_to_role = module.lgtm_storage.service_account_to_role
    }

    registry = module.ecr.registry_url
  }
}
