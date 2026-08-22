###############################################################################
# modules/telemetry-gateway — input variables
###############################################################################

variable "cluster_name" {
  description = "Name of Cluster B. Used for resource naming and tags only."
  type        = string
}

variable "namespace" {
  description = "Namespace the gateway runs in. Created by this module."
  type        = string
  default     = "telemetry"
}

variable "gateway_dns_name" {
  description = <<-EOT
    Fully qualified name Cluster A connects to. Must match the certificate SAN
    exactly — a mismatch fails the TLS handshake after the TCP connection has
    already succeeded, which reads like a network fault and is not one.
  EOT
  type        = string
}

variable "route53_zone_id" {
  description = "Private hosted zone the gateway record is created in."
  type        = string
}

variable "cert_manager_namespace" {
  description = "Namespace cert-manager runs in, where the CA secret is read from."
  type        = string
  default     = "cert-manager"
}

variable "certs_chart_path" {
  description = "Filesystem path to charts/telemetry-certs, relative to this module."
  type        = string
  default     = "../../../charts/telemetry-certs"
}

# --- Load balancer -------------------------------------------------------------

variable "nlb_subnet_ids" {
  description = "Private subnets in the observability VPC the internal NLB places its ENIs in."
  type        = list(string)
}

variable "nlb_security_group_ids" {
  description = <<-EOT
    Security groups attached to the NLB itself. Pass the otlp_ingress group from
    modules/security. This is where the workload-VPC CIDR restriction actually
    takes effect: client IP preservation is off by default for NLB ip targets,
    so a group attached only to the nodes never observes Cluster A's address.
  EOT
  type        = list(string)
}

# --- Chart and image -----------------------------------------------------------

variable "chart_repository" {
  description = "OCI registry holding the mirrored Alloy chart."
  type        = string
}

variable "chart_version" {
  description = "Exact Alloy chart version, matching ALLOY_CHART_VERSION in scripts/mirror-images.sh."
  type        = string
}

variable "image_registry" {
  description = "ECR registry hostname. Kept separate from the repository path: the chart concatenates them, and an empty registry produces a leading slash and an invalid image reference."
  type        = string
}

variable "image_repository" {
  description = "Repository path within the registry, e.g. mirror/grafana/alloy."
  type        = string
  default     = "mirror/grafana/alloy"
}

variable "image_tag" {
  description = "Exact Alloy image tag, matching ALLOY_IMAGE_TAG in scripts/mirror-images.sh."
  type        = string
}

variable "replicas" {
  description = "Gateway replicas. Two spreads ingest across AZs and survives a node roll."
  type        = number
  default     = 2
}

# --- Pipeline ------------------------------------------------------------------

variable "lgtm_enabled" {
  description = <<-EOT
    Render the Mimir, Loki and Tempo exporters. Leave false until the LGTM
    stack exists in Cluster B; a rendered exporter with no backend fails on
    every batch and buries the real signal in retry noise.
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
  description = "Tempo OTLP/gRPC endpoint inside Cluster B, host:port. Only used when lgtm_enabled is true."
  type        = string
  default     = "tempo-distributor.lgtm.svc.cluster.local:4317"
}

variable "log_level" {
  description = "Alloy's own log level."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be one of debug, info, warn, error."
  }
}

variable "memory_limit" {
  description = "Soft memory ceiling for the memory_limiter processor. Keep below the container memory limit."
  type        = string
  default     = "512MiB"
}

variable "cert_wait_duration" {
  description = "How long to wait after the certificate chart before reading the CA secret. cert-manager issues in seconds; this is slack, not a timeout."
  type        = string
  default     = "60s"
}

variable "tags" {
  description = "Tags merged onto every AWS resource in this module."
  type        = map(string)
  default     = {}
}
