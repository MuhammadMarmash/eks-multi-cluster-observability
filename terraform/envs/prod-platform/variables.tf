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
    Leave false until the LGTM stack exists in Cluster B; until then the debug
    sink in the gateway's pod logs is how arrival is confirmed.
  EOT
  type        = bool
  default     = false
}

variable "mimir_endpoint" {
  description = "Mimir OTLP endpoint inside Cluster B. Only used when lgtm_enabled is true."
  type        = string
  default     = "http://mimir-nginx.lgtm.svc.cluster.local/otlp"
}

variable "loki_endpoint" {
  description = "Loki OTLP endpoint inside Cluster B. Only used when lgtm_enabled is true."
  type        = string
  default     = "http://loki-gateway.lgtm.svc.cluster.local/otlp"
}

variable "tempo_endpoint" {
  description = "Tempo OTLP/gRPC endpoint inside Cluster B. Only used when lgtm_enabled is true."
  type        = string
  default     = "tempo-distributor.lgtm.svc.cluster.local:4317"
}

variable "scrape_interval" {
  description = "kubelet and cAdvisor scrape interval on Cluster A."
  type        = string
  default     = "60s"
}
