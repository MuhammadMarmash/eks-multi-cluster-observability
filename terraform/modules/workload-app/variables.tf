###############################################################################
# modules/workload-app — input variables
###############################################################################

variable "namespace" {
  description = "Namespace the application runs in on Cluster A."
  type        = string
  default     = "boutique"
}

variable "agent_otlp_endpoint" {
  description = <<-EOT
    Host of the Alloy agent the services send OTLP to. Host only, no scheme and
    no port — the chart appends the port itself.

    This is the entire integration: the application knows nothing about
    Cluster B, only about the agent running beside it.
  EOT
  type        = string
}

variable "chart_repository" {
  description = "OCI registry holding the mirrored chart."
  type        = string
}

variable "chart_version" {
  description = "opentelemetry-demo chart version. Matches OTEL_DEMO_CHART_VERSION in scripts/mirror-images.sh."
  type        = string
  default     = "0.41.0"
}

variable "image_registry" {
  description = "ECR registry hostname."
  type        = string
}

variable "app_version" {
  description = "Demo appVersion. Every service image is this value plus a component suffix."
  type        = string
  default     = "3.0.0"
}

variable "flagd_image_tag" {
  description = "flagd image tag."
  type        = string
  default     = "v0.16.0"
}

variable "postgres_image_tag" {
  description = "PostgreSQL image tag, backing product-catalog."
  type        = string
  default     = "18.4"
}

variable "valkey_image_tag" {
  description = "Valkey image tag."
  type        = string
  default     = "9.0.4-alpine3.23"
}

variable "disabled_components" {
  description = <<-EOT
    Demo components not deployed.

    The chart ships twenty-six, including a chatbot, an MCP server and a Kafka
    cluster. Cluster A has two nodes; this trims to the storefront path that
    actually produces traces. Kafka and its two consumers go together —
    accounting and fraud-detection only read from it.
  EOT
  type        = list(string)
  # astronomy-db and kafka are deliberately NOT here. product-catalog and
  # checkout each block on an init container that waits for one of them, so
  # disabling either leaves those services in Init forever and removes the
  # storefront's most interesting traces. accounting and fraud-detection only
  # CONSUME from Kafka, so they can go without affecting checkout.
  default = [
    "chatbot", "mcp", "firepit", "opamp-server", "telemetry-docs",
    "accounting", "fraud-detection", "image-provider",
  ]
}
