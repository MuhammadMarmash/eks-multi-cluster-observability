###############################################################################
# modules/irsa — input variables
###############################################################################

variable "role_name" {
  description = "Name of the IAM role. Must be unique within the account."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider. Comes from the eks module's oidc_provider_arn output."
  type        = string
}

variable "oidc_provider_host" {
  description = "OIDC issuer without the https:// scheme — the exact string used as the condition key prefix. Comes from the eks module's oidc_provider_host output."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of the ServiceAccount allowed to assume this role."
  type        = string
}

variable "service_account" {
  description = "Name of the ServiceAccount allowed to assume this role."
  type        = string

  validation {
    condition     = !strcontains(var.service_account, "*")
    error_message = "service_account must be an exact name. A wildcard would let any ServiceAccount in the namespace assume this role."
  }
}

variable "managed_policy_arns" {
  description = "AWS managed or customer managed policy ARNs to attach."
  type        = list(string)
  default     = []
}

variable "inline_policy_json" {
  description = "Optional inline policy document. Use for policies that exist only for this role, such as the AWS Load Balancer Controller policy."
  type        = string
  default     = null
}

variable "description" {
  description = "Human-readable description recorded on the role."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
