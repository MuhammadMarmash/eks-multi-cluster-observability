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
