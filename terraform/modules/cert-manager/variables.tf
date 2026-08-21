###############################################################################
# modules/cert-manager — input variables
###############################################################################

variable "namespace" {
  description = <<-EOT
    Namespace cert-manager runs in. Also the cluster resource namespace: a
    ClusterIssuer of type `ca` reads its signing secret from here regardless of
    where the Certificate it signs lives. Changing this means changing
    charts/telemetry-certs' certManagerNamespace to match.
  EOT
  type        = string
  default     = "cert-manager"
}

variable "chart_repository" {
  description = "OCI registry holding the mirrored chart."
  type        = string
}

variable "chart_version" {
  description = "Exact chart version, matching CERT_MANAGER_VERSION in scripts/mirror-images.sh."
  type        = string
}

variable "image_registry" {
  description = "ECR registry hostname, e.g. <account>.dkr.ecr.<region>.amazonaws.com. Component repository paths are appended to it."
  type        = string
}

variable "labels" {
  description = "Labels applied to the namespace."
  type        = map(string)
  default     = {}
}
