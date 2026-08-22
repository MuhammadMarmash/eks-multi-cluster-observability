###############################################################################
# modules/telemetry-agent — input variables
#
# This module knows nothing about Cluster B beyond a hostname, a CA and a
# credential. All three are inputs, wired by the root module.
###############################################################################

variable "cluster_name" {
  description = "Name of Cluster A. Stamped onto every signal as the `cluster` resource attribute, which is how Grafana tells the two clusters apart."
  type        = string
}

variable "namespace" {
  description = "Namespace the agent runs in. Created by this module."
  type        = string
  default     = "telemetry"
}

variable "gateway_endpoint" {
  description = "host:port of the gateway in Cluster B. Must be the name the gateway certificate is issued for."
  type        = string
}

variable "gateway_ca_pem" {
  description = "PEM of the CA that signed the gateway certificate. Public material; comes from the gateway module's ca_certificate_pem output."
  type        = string

  validation {
    condition     = can(regex("BEGIN CERTIFICATE", var.gateway_ca_pem))
    error_message = "gateway_ca_pem must be a PEM certificate. An empty value usually means the CA secret was read before cert-manager had issued it."
  }
}

variable "ingest_username" {
  description = "Username the agent authenticates to the gateway with."
  type        = string
}

variable "ingest_password" {
  description = "Password the agent authenticates to the gateway with."
  type        = string
  sensitive   = true
}

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

variable "scrape_interval" {
  description = "How often kubelet and cAdvisor are scraped. 60s keeps cardinality and cost down for a lab; 15s is the production reflex."
  type        = string
  default     = "60s"
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
  default     = "384MiB"
}
