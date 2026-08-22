###############################################################################
# envs/prod-platform — input variables
###############################################################################

variable "aws_region" {
  description = "Region both clusters run in."
  type        = string
  default     = "eu-west-1"
}

variable "allowed_account_ids" {
  description = "Guard rail: refuse to run against any other account."
  type        = list(string)
  default     = []
}

# --- Where the infrastructure state lives ------------------------------------

variable "infra_state_bucket" {
  description = "S3 bucket holding the envs/prod state. Same bucket as this root module's own backend."
  type        = string
}

variable "infra_state_key" {
  description = "Key of the envs/prod state object."
  type        = string
  default     = "prod/platform.tfstate"
}

# --- Naming --------------------------------------------------------------------

variable "private_zone_name" {
  description = "Private hosted zone for cross-cluster service discovery."
  type        = string
  default     = "observability.internal"
}

variable "gateway_hostname" {
  description = "Leftmost label of the gateway record. The full name becomes <gateway_hostname>.<private_zone_name>."
  type        = string
  default     = "gateway"
}

variable "telemetry_namespace" {
  description = "Namespace the agent and the gateway each run in, on their own clusters."
  type        = string
  default     = "telemetry"
}

# --- Pinned versions -----------------------------------------------------------
#
# Every one of these must match a tag that scripts/mirror-images.sh has already
# pushed into ECR, or the release fails to pull.

variable "alloy_chart_version" {
  description = "Alloy chart version. Matches ALLOY_CHART_VERSION in scripts/mirror-images.sh."
  type        = string
  default     = "1.4.0"
}

variable "alloy_image_tag" {
  description = "Alloy image tag. Matches ALLOY_IMAGE_TAG in scripts/mirror-images.sh."
  type        = string
  default     = "v1.12.0"
}

variable "alb_chart_version" {
  description = "AWS Load Balancer Controller chart version. Matches ALB_CHART_VERSION in scripts/mirror-images.sh."
  type        = string
  default     = "1.13.4"
}

variable "alb_image_tag" {
  description = "AWS Load Balancer Controller image tag. Matches ALB_IMAGE_TAG and the iam-policy.json tag in modules/aws-lb-controller."
  type        = string
  default     = "v2.13.4"
}

variable "cert_manager_version" {
  description = "cert-manager chart and image version. Matches CERT_MANAGER_VERSION in scripts/mirror-images.sh."
  type        = string
  default     = "v1.19.1"
}

# --- Pipeline ------------------------------------------------------------------

variable "gateway_replicas" {
  description = "Gateway replicas on Cluster B."
  type        = number
  default     = 2
}

variable "lgtm_enabled" {
  description = <<-EOT
    Route gateway output to Mimir, Loki and Tempo instead of the debug sink.

    True now that the backends are deployed in the same root module. Setting it
    false falls back to the debug sink, which is still the fastest way to prove
    telemetry is ARRIVING when the question is whether the problem is the
    cross-cluster hop or a backend.
  EOT
  type        = bool
  default     = true
}




variable "scrape_interval" {
  description = "kubelet and cAdvisor scrape interval on Cluster A."
  type        = string
  default     = "60s"
}

variable "grafana_chart_version" {
  description = "Grafana chart version. Matches scripts/mirror-images.sh."
  type        = string
  default     = "10.5.15"
}

variable "grafana_image_tag" {
  description = "Grafana image tag (chart 10.5.15 appVersion)."
  type        = string
  default     = "12.3.1"
}

variable "metrics_server_chart_version" {
  description = "metrics-server chart version. Matches scripts/mirror-images.sh."
  type        = string
  default     = "3.14.0"
}

variable "metrics_server_image_tag" {
  description = "metrics-server image tag (chart 3.14.0 appVersion)."
  type        = string
  default     = "v0.9.0"
}

# --- LGTM backends -------------------------------------------------------------

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

    Single-binary rather than tempo-distributed: one pod instead of six, which
    is what makes the stack fit on t3.medium. Both charts are deprecated
    upstream; this one is a sixth of the footprint.
  EOT
  type        = string
  default     = "1.24.4"
}

variable "lgtm_replication_factor" {
  description = <<-EOT
    Ingester replication factor shared by all three backends.

    All three charts default to 3, which is also their MINIMUM ingester count —
    left alone on a scaled-down cluster the ring never becomes healthy and every
    write is refused, with no error at deploy time. 1 is the cost-sane demo
    choice and means un-flushed data sits on exactly one ingester.
  EOT
  type        = number
  default     = 1
}

variable "lgtm_ingester_replicas" {
  description = "Ingester replicas per backend. Must be >= lgtm_replication_factor."
  type        = number
  default     = 2
}

variable "lgtm_enable_caches" {
  description = <<-EOT
    Deploy the memcached tiers. Off by default: Loki's chunksCache alone
    requests 8192Mi, an entire t3.large, before Loki has started.
  EOT
  type        = bool
  default     = false
}
