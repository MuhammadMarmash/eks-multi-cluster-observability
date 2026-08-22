###############################################################################
# modules/metrics-server — input variables
###############################################################################

variable "cluster_name" {
  description = "Cluster this instance runs on. Naming and tagging only."
  type        = string
}

variable "namespace" {
  description = "Namespace to install into. kube-system always exists, so this module creates nothing."
  type        = string
  default     = "kube-system"
}

variable "chart_repository" {
  description = "OCI registry holding the mirrored chart."
  type        = string
}

variable "chart_version" {
  description = "metrics-server chart version. Matches METRICS_SERVER_CHART_VERSION in scripts/mirror-images.sh."
  type        = string
  default     = "3.14.0"
}

variable "image_repository" {
  description = "ECR repository holding the mirrored metrics-server image."
  type        = string
  default     = "mirror/metrics-server/metrics-server"
}

variable "image_registry" {
  description = "ECR registry hostname. Kept separate from the repository path because the chart joins them."
  type        = string
}

variable "image_tag" {
  description = "metrics-server image tag (chart 3.14.0 appVersion)."
  type        = string
  default     = "v0.9.0"
}

variable "replicas" {
  description = <<-EOT
    metrics-server replicas.

    One is correct here. It is a cache in front of the kubelets, not a source of
    truth: a restart costs a few seconds of `kubectl top` and an HPA evaluation
    cycle, and nothing durable. Two replicas on a three-node cluster would cost
    more than that gap is worth.
  EOT
  type        = number
  default     = 1
}
