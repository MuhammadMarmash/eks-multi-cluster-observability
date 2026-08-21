###############################################################################
# envs/prod-platform — providers
#
# Four aliased providers, one per (tool, cluster) pair. Every module call names
# the cluster it targets explicitly, so there is no default provider to
# accidentally deploy the agent into the observability cluster.
#
# The clusters already exist when this root module runs — that is the entire
# reason it is a separate root module. Deriving provider configuration from
# resources created in the same apply plans badly on green-field and worse on
# destroy.
#   docs/adr/0008-two-stage-terraform.md
###############################################################################

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Layer     = "kubernetes-platform"
    }
  }
}

# --- Cluster A (workload) --------------------------------------------------------

provider "kubernetes" {
  alias = "workload"

  host                   = data.aws_eks_cluster.workload.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.workload.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.workload_cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  alias = "workload"

  kubernetes = {
    host                   = data.aws_eks_cluster.workload.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.workload.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.workload_cluster_name, "--region", var.aws_region]
    }
  }

  registries = [
    {
      url      = local.chart_registry
      username = data.aws_ecr_authorization_token.this.user_name
      password = data.aws_ecr_authorization_token.this.password
    },
  ]
}

# --- Cluster B (observability) ---------------------------------------------------

provider "kubernetes" {
  alias = "observability"

  host                   = data.aws_eks_cluster.observability.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.observability.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.observability_cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  alias = "observability"

  kubernetes = {
    host                   = data.aws_eks_cluster.observability.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.observability.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.observability_cluster_name, "--region", var.aws_region]
    }
  }

  registries = [
    {
      url      = local.chart_registry
      username = data.aws_ecr_authorization_token.this.user_name
      password = data.aws_ecr_authorization_token.this.password
    },
  ]
}
