###############################################################################
# modules/lgtm-backends — input variables
###############################################################################

variable "namespace" {
  description = <<-EOT
    Namespace the three backends run in. MUST equal the namespace pinned in the
    IRSA trust policies built by modules/lgtm-storage — a trust policy is scoped
    to namespace/ServiceAccount, so a mismatch means no pod can assume its role.
  EOT
  type        = string
  default     = "lgtm"
}

variable "aws_region" {
  description = "Region the S3 buckets live in."
  type        = string
}

variable "buckets" {
  description = "Bucket name per component, keyed mimir/loki/tempo. From envs/prod's lgtm_bucket_names output."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["mimir", "loki", "tempo"] : contains(keys(var.buckets), k)])
    error_message = "buckets must contain keys mimir, loki and tempo."
  }
}

variable "irsa_role_arns" {
  description = "IAM role ARN per component, keyed mimir/loki/tempo. From envs/prod's lgtm_irsa_role_arns output."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["mimir", "loki", "tempo"] : contains(keys(var.irsa_role_arns), k)])
    error_message = "irsa_role_arns must contain keys mimir, loki and tempo."
  }
}

variable "service_account_names" {
  description = <<-EOT
    ServiceAccount name per component. From envs/prod's lgtm_storage module.

    These are PINNED, not chosen here. Each chart's default derives the name
    from the Helm release name (`m-mimir`, `t-tempo`), which the layer that
    wrote the trust policies could not know. Overriding them is what makes IRSA
    work at all; if it drifts the pod is issued no role, silently falls back to
    the node instance role, and fails on its first S3 write with an opaque
    AccessDenied.
  EOT
  type        = map(string)

  default = {
    mimir = "mimir-sa"
    loki  = "loki-sa"
    tempo = "tempo-sa"
  }
}

# --- Charts and images ---------------------------------------------------------

variable "chart_repository" {
  description = "OCI registry holding the mirrored charts."
  type        = string
}

variable "image_registry" {
  description = "ECR registry hostname. Component image paths are appended to it."
  type        = string
}

variable "mimir_chart_version" {
  description = "mimir-distributed chart version. Matches scripts/mirror-images.sh."
  type        = string
  default     = "6.2.0"
}

variable "loki_chart_version" {
  description = "loki chart version. Matches scripts/mirror-images.sh."
  type        = string
  default     = "7.3.0"
}

variable "tempo_chart_version" {
  description = <<-EOT
    grafana/tempo (single-binary) chart version. Matches scripts/mirror-images.sh.

    The single-binary chart, not tempo-distributed: one pod instead of six,
    which is what makes the stack fit on t3.medium nodes. Both charts are
    deprecated upstream; this one is a sixth of the footprint.
  EOT
  type        = string
  default     = "1.24.4"
}

variable "mimir_image_tag" {
  description = "Mimir image tag (chart 6.2.0 appVersion)."
  type        = string
  default     = "3.2.0"
}

variable "loki_image_tag" {
  description = "Loki image tag (chart 7.3.0 appVersion)."
  type        = string
  default     = "3.6.12"
}

variable "tempo_image_tag" {
  description = "Tempo image tag (chart 1.24.4 appVersion)."
  type        = string
  default     = "2.9.0"
}

variable "nginx_image_tag" {
  description = "nginx-unprivileged tag used by the Mimir and Loki gateways."
  type        = string
  default     = "1.29-alpine"
}

variable "rollout_operator_image_tag" {
  description = <<-EOT
    grafana/rollout-operator tag.

    Must match the appVersion of the rollout-operator SUBCHART, not the parent
    chart and not the latest release:

      helm show chart grafana/mimir-distributed --version <v> # parent only
      grep appVersion charts/rollout-operator/Chart.yaml      # this one

    The chart passes flags that only exist in its own appVersion. An older tag
    starts, rejects the flag, prints its help text and exits — and because the
    operator serves a prepare-downscale admission webhook, every StatefulSet
    patch in the namespace then fails with "no endpoints available".
  EOT
  type        = string
  default     = "v0.38.1"
}

# --- Sizing --------------------------------------------------------------------

variable "replication_factor" {
  description = <<-EOT
    Ingester replication factor for Mimir, Loki and Tempo.

    All three default to 3, which also sets their MINIMUM ingester count — a
    chart left at the default will not start on a two-node t3.large cluster.
    1 is the cost-sane choice for a demo and means un-flushed data lives on
    exactly one ingester. Raise to 3 with matching ingester counts before this
    carries anything anyone depends on.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.replication_factor >= 1 && var.replication_factor <= 3
    error_message = "replication_factor must be between 1 and 3."
  }
}

variable "ingester_replicas" {
  description = "Ingester replicas for each backend. Must be >= replication_factor."
  type        = number
  default     = 2

  validation {
    condition     = var.ingester_replicas >= 1
    error_message = "ingester_replicas must be at least 1."
  }
}

variable "enable_caches" {
  description = <<-EOT
    Deploy the memcached tiers (Loki chunks/results cache, Tempo memcached).

    Off by default and that is not a small saving: Loki's chunksCache alone
    requests 8192 MiB, which is an entire t3.large node. Turn these on only
    after the node group has room for them.
  EOT
  type        = bool
  default     = false
}

variable "enable_mimir_ruler_and_alertmanager" {
  description = <<-EOT
    Deploy Mimir's ruler and alertmanager.

    Off by default to save CPU on a two-node cluster. Note that both write to
    object storage under their own prefixes in the Mimir bucket, so enabling
    them needs no new bucket or IAM change — only capacity.
  EOT
  type        = bool
  default     = false
}

variable "ingester_wal_size" {
  description = <<-EOT
    Size of the Mimir ingester's write-ahead-log volume.

    This is the one PVC in the stack, and it is NOT durable storage — blocks go
    to S3. It exists so a restarting ingester does not lose every sample taken
    since its last block flush, which is up to two hours. It only ever holds one
    block period, so it stays small.
  EOT
  type        = string
  default     = "2Gi"
}

variable "log_level" {
  description = "Log level for all three backends."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be one of debug, info, warn, error."
  }
}

variable "mimir_push_endpoint" {
  description = <<-EOT
    Prometheus remote-write endpoint that Tempo's metrics generator pushes span
    and service-graph metrics to.

    Through Mimir's gateway rather than its distributor: the gateway injects the
    X-Scope-OrgID tenant header, and Mimir rejects a write without one with
    "401: no org id".
  EOT
  type        = string
  default     = "http://mimir-gateway.lgtm.svc.cluster.local/api/v1/push"
}
