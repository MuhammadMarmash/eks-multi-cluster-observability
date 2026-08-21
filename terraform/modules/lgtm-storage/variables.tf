###############################################################################
# modules/lgtm-storage — input variables
###############################################################################

variable "name_prefix" {
  description = "Prefix for bucket and role names, e.g. \"obs-platform-prod\"."
  type        = string
}

variable "account_id" {
  description = <<-EOT
    AWS account ID, appended to every bucket name. S3 bucket names are globally
    unique across all AWS accounts, so a plain project slug will eventually
    collide with a stranger's bucket and fail at apply time on a name that
    cannot be taken. Passed in rather than read from a data source so the module
    stays testable offline.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "cluster_name" {
  description = "Name of the observability cluster (Cluster B). Used in IAM role names."
  type        = string
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider ARN of the observability cluster. From the eks module's oidc_provider_arn output."
  type        = string
}

variable "oidc_provider_host" {
  description = "OIDC issuer host without the scheme. From the eks module's oidc_provider_host output."
  type        = string
}

variable "namespace" {
  description = <<-EOT
    Namespace the LGTM stack runs in. Deliberately NOT the telemetry namespace
    that holds the gateway: an IRSA trust policy is scoped to
    namespace/ServiceAccount, so sharing a namespace would widen who can assume
    these roles.
  EOT
  type        = string
  default     = "lgtm"
}

variable "components" {
  description = <<-EOT
    The three object stores, keyed by component. Defaults encode the decisions
    in ADR 0010 and should not be changed without revisiting it.

    transition_ia_days = null means the objects stay in S3 Standard for their
    whole life. That is correct for Tempo and wrong for the other two — see the
    module header.
  EOT
  type = map(object({
    signal             = string
    service_account    = string
    transition_ia_days = optional(number)
    expiration_days    = number
  }))

  default = {
    mimir = {
      signal             = "metrics"
      service_account    = "mimir-sa"
      transition_ia_days = 30
      expiration_days    = 90
    }
    loki = {
      signal             = "logs"
      service_account    = "loki-sa"
      transition_ia_days = 30
      expiration_days    = 90
    }
    tempo = {
      signal             = "traces"
      service_account    = "tempo-sa"
      transition_ia_days = null # Standard for life — random-access retrieval
      expiration_days    = 30
    }
  }

  validation {
    condition = alltrue([
      for c in var.components :
      c.transition_ia_days == null || c.transition_ia_days >= 30
    ])
    error_message = "Standard-IA has a 30-day minimum billable duration. Transitioning earlier is billed as 30 days anyway and saves nothing."
  }

  validation {
    condition = alltrue([
      for c in var.components :
      c.transition_ia_days == null || c.expiration_days > c.transition_ia_days
    ])
    error_message = "expiration_days must be later than transition_ia_days, or objects are deleted before they ever reach Standard-IA."
  }
}

variable "abort_incomplete_multipart_upload_days" {
  description = <<-EOT
    Days after which an incomplete multipart upload is abandoned and reaped.

    This is not housekeeping. An aborted multipart upload keeps billing for its
    uploaded parts indefinitely and does NOT appear in an object listing, so the
    cost is both permanent and invisible. Compactors produce them on every OOM
    or eviction.
  EOT
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
