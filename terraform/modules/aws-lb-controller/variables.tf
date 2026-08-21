###############################################################################
# modules/aws-lb-controller — input variables
###############################################################################

variable "cluster_name" {
  description = "EKS cluster this controller manages load balancers for. The controller will not start without it."
  type        = string
}

variable "vpc_id" {
  description = "VPC the cluster runs in. Pinning it avoids an IMDS lookup at startup."
  type        = string
}

variable "region" {
  description = "AWS region the cluster runs in."
  type        = string
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider ARN of the cluster, for the IRSA trust policy."
  type        = string
}

variable "oidc_provider_host" {
  description = "OIDC issuer host without the scheme, for the IRSA condition keys."
  type        = string
}

variable "namespace" {
  description = "Namespace to install into. Must already exist — kube-system always does."
  type        = string
  default     = "kube-system"
}

variable "chart_repository" {
  description = "OCI registry holding the mirrored chart, e.g. oci://<account>.dkr.ecr.<region>.amazonaws.com/charts."
  type        = string
}

variable "chart_version" {
  description = "Exact chart version. Never floating — a surprise controller upgrade takes the ingress path with it."
  type        = string
}

variable "image_repository" {
  description = "ECR repository holding the mirrored controller image."
  type        = string
}

variable "image_tag" {
  description = "Exact image tag. Keep in step with ALB_IMAGE_TAG in scripts/mirror-images.sh and with the tag in the iam-policy.json download URL."
  type        = string
}

variable "replicas" {
  description = "Controller replicas. Two gives leader-election failover; one is enough for a lab."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags merged onto every AWS resource in this module."
  type        = map(string)
  default     = {}
}
