variable "aws_region" {
  description = "Region hosting the state bucket. Must match the `region` in the backend block of every consuming root module."
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Project slug used in resource names and tags."
  type        = string
  default     = "obs-platform"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state, e.g. \"obs-platform-tfstate-123456789012\"."
  type        = string
}

variable "use_customer_managed_key" {
  description = "Encrypt state with a customer managed KMS key instead of SSE-S3. Adds key-usage auditing and per-key access control at ~$1/month."
  type        = bool
  default     = true
}

# --- GitHub Actions OIDC ---------------------------------------------------------

variable "github_repository" {
  description = <<-EOT
    Repository allowed to assume the CI roles, as "owner/repo".

    Leave empty to skip creating the OIDC provider and roles entirely — useful
    when bootstrapping an account before the repository exists.

    This value ends up in an IAM trust policy. It must be the exact
    "owner/repo"; a wildcard here would let any repository in the organisation
    assume the roles, which is the same failure mode modules/irsa guards against
    for ServiceAccounts.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.github_repository == "" || can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be exactly \"owner/repo\" with no wildcards."
  }
}

variable "infra_environment_name" {
  description = <<-EOT
    GitHub Environment that gates the infrastructure apply.

    The apply role's trust policy pins this name, so the token cannot be issued
    unless the job is running in this Environment — which means a human approved
    it. Changing it here without changing the workflow breaks every apply.
  EOT
  type        = string
  default     = "prod-infra"
}

variable "platform_environment_name" {
  description = "GitHub Environment that gates the Kubernetes-layer apply. Pinned in the apply role's trust policy."
  type        = string
  default     = "prod-platform"
}
