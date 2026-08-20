###############################################################################
# modules/ecr — input variables
###############################################################################

variable "repositories" {
  description = <<-EOT
    ECR repositories to create, keyed by repository name. Names may contain
    slashes to namespace them, e.g. "boutique/cartservice" or "charts/lgtm".

    Per-repository overrides exist for the lifecycle policy only; the security
    controls (immutability, scan-on-push, encryption) are enforced module-wide
    and are deliberately NOT overridable per repository.
  EOT
  type = map(object({
    description          = optional(string, "")
    keep_last_n_images   = optional(number, 30)
    untagged_expiry_days = optional(number, 7)
    protected_tag_prefix = optional(string, "v")
  }))
}

variable "image_tag_mutability" {
  description = <<-EOT
    IMMUTABLE means a tag can never be repointed at a different digest once
    pushed. This is a hard production requirement: it makes `app:1.4.2`
    reproducible forever, prevents a compromised CI job from silently swapping
    the contents of a released tag, and keeps GitOps rollbacks honest.
  EOT
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["IMMUTABLE", "MUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be IMMUTABLE or MUTABLE (production standard is IMMUTABLE)."
  }
}

variable "scan_on_push" {
  description = "Run a basic (CVE) vulnerability scan on every pushed image. Nothing enters the cluster unscanned."
  type        = bool
  default     = true
}

variable "enable_enhanced_scanning" {
  description = <<-EOT
    Switch the whole REGISTRY to Amazon Inspector enhanced scanning: continuous
    rescanning of already-pushed images as new CVEs are published, plus OS and
    language-package coverage.

    NOTE: this is an account+Region-wide setting, not per repository. Enable it
    in exactly one Terraform root module to avoid two states fighting over it.
    It is also billed per image scanned, hence off by default.
  EOT
  type        = bool
  default     = false
}

variable "encryption_type" {
  description = "KMS or AES256. KMS with kms_key = null uses the AWS-managed aws/ecr key, which adds CloudTrail visibility over key usage at no extra key cost."
  type        = string
  default     = "KMS"

  validation {
    condition     = contains(["KMS", "AES256"], var.encryption_type)
    error_message = "encryption_type must be KMS or AES256."
  }
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for repository encryption. Null uses the AWS-managed aws/ecr key."
  type        = string
  default     = null
}

variable "force_delete" {
  description = "Allow `terraform destroy` to delete repositories that still contain images. Convenient for a cost-capped lab; set false for anything real."
  type        = bool
  default     = false
}

variable "pull_principal_arns" {
  description = <<-EOT
    IAM principals granted pull-only access through a repository policy.

    Usually EMPTY: the EKS node roles already hold
    AmazonEC2ContainerRegistryReadOnly, which is sufficient for same-account
    pulls. Populate this only for cross-account access or for a CI role in
    another account.
  EOT
  type        = list(string)
  default     = []
}

variable "push_principal_arns" {
  description = "IAM principals granted push access (typically the GitHub Actions OIDC role). Empty means push rights come from identity-based policies only."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
