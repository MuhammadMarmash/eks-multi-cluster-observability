###############################################################################
# modules/grafana — input variables
###############################################################################

variable "namespace" {
  description = "Namespace Grafana runs in. Shares the LGTM namespace so datasource URLs stay short and NetworkPolicy stays simple."
  type        = string
  default     = "lgtm"
}

variable "create_namespace" {
  description = "Create the namespace. False when another module already owns it — which is the case when Grafana shares the LGTM namespace."
  type        = bool
  default     = false
}

variable "datasource_urls" {
  description = <<-EOT
    Read endpoints per backend, keyed mimir/loki/tempo. From the lgtm-backends
    module's query_endpoints output.

    Mimir and Loki are reached through their nginx gateways rather than their
    query-frontends directly. That is deliberate: the Mimir gateway injects the
    X-Scope-OrgID tenant header, without which Mimir rejects every query.
  EOT
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["mimir", "loki", "tempo"] : contains(keys(var.datasource_urls), k)])
    error_message = "datasource_urls must contain keys mimir, loki and tempo."
  }
}

variable "chart_repository" {
  description = "OCI registry holding the mirrored chart."
  type        = string
}

variable "chart_version" {
  description = "Grafana chart version. Matches scripts/mirror-images.sh."
  type        = string
  default     = "10.5.15"
}

variable "image_registry" {
  description = "ECR registry hostname. Kept separate from the repository path: the chart concatenates them, and an empty registry produces a leading slash and an invalid image reference."
  type        = string
}

variable "image_repository" {
  description = "Repository path within the registry, e.g. mirror/grafana/grafana."
  type        = string
  default     = "mirror/grafana/grafana"
}

variable "image_tag" {
  description = "Grafana image tag (chart 10.5.15 appVersion)."
  type        = string
  default     = "12.3.1"
}

variable "admin_user" {
  description = "Grafana admin username."
  type        = string
  default     = "admin"
}

variable "service_account_name" {
  description = <<-EOT
    ServiceAccount Grafana runs as.

    It carries NO IRSA annotation, deliberately. Grafana reads through the
    Mimir, Loki and Tempo APIs over HTTP and has no business holding an S3
    credential — and it is the only component in the stack exposed to humans,
    which makes it the one most worth keeping away from the data at rest.
      docs/adr/0010-cloud-native-storage-and-irsa.md
  EOT
  type        = string
  default     = "grafana-sa"
}
