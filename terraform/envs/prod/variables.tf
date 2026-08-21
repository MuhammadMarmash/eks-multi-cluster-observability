###############################################################################
# envs/prod — input variables
###############################################################################

# --- Account / naming ----------------------------------------------------------

variable "aws_region" {
  description = "Region for the whole platform. Both VPCs and both clusters are Region-local; VPC peering here is intra-Region."
  type        = string
  default     = "eu-west-1"
}

variable "allowed_account_ids" {
  description = "AWS account IDs this configuration is permitted to touch. Empty disables the guard rail (not recommended)."
  type        = list(string)
  default     = []
}

variable "project" {
  description = "Project slug used as the prefix for cluster and resource names."
  type        = string
  default     = "obs-platform"
}

variable "environment" {
  description = "Environment name, used in tags and cluster names."
  type        = string
  default     = "prod"
}

variable "cost_center" {
  description = "Cost-allocation tag value. Every resource carries it via provider default_tags, so Cost Explorer can split workload vs observability spend."
  type        = string
  default     = "platform-engineering"
}

variable "repository_url" {
  description = "Git repository that owns this infrastructure. Tagged onto every resource so an on-call engineer can find the source of any resource."
  type        = string
  default     = "https://github.com/CHANGE-ME/devops-project3"
}

variable "az_count" {
  description = "Number of Availability Zones each VPC spans. Three is the production default; two is the supported minimum for EKS."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

# --- Networking ----------------------------------------------------------------

variable "workload_vpc_cidr" {
  description = "CIDR for vpc-workload (Cluster A). MUST NOT overlap observability_vpc_cidr — VPC peering rejects overlapping CIDRs outright."
  type        = string
  default     = "10.0.0.0/16"
}

variable "observability_vpc_cidr" {
  description = "CIDR for vpc-observability (Cluster B)."
  type        = string
  default     = "10.1.0.0/16"
}

variable "single_nat_gateway" {
  description = <<-EOT
    true  -> one NAT gateway per VPC (2 total). ~$65/month, single-AZ egress.
    false -> one NAT gateway per AZ per VPC (6 total). ~$195/month, HA egress.

    Defaulted to true for the cost-capped lab account; flip to false for a real
    production rollout, where losing egress in one AZ must not stall image
    pulls or telemetry export cluster-wide.
  EOT
  type        = bool
  default     = true
}

variable "otlp_ports" {
  description = "OTLP ports opened from the workload VPC to the observability VPC across the peering link."
  type        = list(number)
  default     = [4317, 4318]
}

# --- EKS -----------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Kubernetes version for BOTH clusters. Day-2 upgrades bump the observability cluster first, then the workload cluster (see the upgrade runbook)."
  type        = string
  default     = "1.34"
}

variable "cluster_endpoint_public_access" {
  description = "Expose the API server publicly. Keep true only while an allow-list is set in cluster_public_access_cidrs."
  type        = bool
  default     = true
}

variable "cluster_public_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the public API endpoint — your office/VPN egress IP
    and the CI runner egress range.

    SECURITY: leaving this at 0.0.0.0/0 exposes the API server (still
    authenticated, but reachable) to the entire internet. Override it in
    terraform.tfvars.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = <<-EOT
    Instance types for both node groups.

    t3.large (2 vCPU / 8 GiB) is specified for the LGTM stack: Mimir ingesters
    and Loki are memory-hungry and t3.medium's 4 GiB leads to OOMKills under
    any real ingest rate. Note that t3.large roughly doubles the compute bill
    versus t3.medium — see the cost table in terraform/README.md before a
    long-running apply.
  EOT
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_desired_size" {
  description = "Desired node count per cluster."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count per cluster."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count per cluster."
  type        = number
  default     = 6
}

variable "enable_prefix_delegation" {
  description = "Turn on VPC CNI prefix delegation (/28 prefixes per ENI) for far higher Pod density per node."
  type        = bool
  default     = true
}

variable "cluster_admin_role_arns" {
  description = "IAM role ARNs granted cluster-admin on BOTH clusters through EKS access entries (e.g. the platform team's SSO role, the CI deploy role)."
  type        = list(string)
  default     = []
}

variable "addon_versions" {
  description = "Optional add-on version pins shared by both clusters, keyed by add-on name (vpc-cni, kube-proxy, coredns, aws-ebs-csi-driver)."
  type        = map(string)
  default     = {}
}

# --- ECR -------------------------------------------------------------------------

variable "ecr_repositories" {
  description = "ECR repositories to create. Defaults cover the mirrored Online Boutique services, the telemetry agents, and the OCI Helm charts."
  type = map(object({
    description          = optional(string, "")
    keep_last_n_images   = optional(number, 30)
    untagged_expiry_days = optional(number, 7)
    protected_tag_prefix = optional(string, "v")
  }))
  default = {
    "boutique/frontend"          = { description = "Mirrored Online Boutique frontend" }
    "boutique/cartservice"       = { description = "Mirrored Online Boutique cart service" }
    "boutique/productcatalog"    = { description = "Mirrored Online Boutique product catalog service" }
    "boutique/checkoutservice"   = { description = "Mirrored Online Boutique checkout service" }
    "boutique/loadgenerator"     = { description = "Mirrored Online Boutique load generator" }
    "observability/lgtm-sidecar" = { description = "Internal sidecar/tooling images for the LGTM stack" }
    "charts/platform"            = { description = "OCI Helm charts for the platform (LGTM values wrappers, boutique umbrella chart)" }

    # Third-party artefacts the Kubernetes layer needs, mirrored so nothing is
    # pulled from a public registry at deploy time (ADR 0005). Versions are
    # pinned in scripts/mirror-images.sh; run `make mirror` to populate these.
    "mirror/grafana/alloy"                         = { description = "Grafana Alloy — the telemetry agent on Cluster A and the gateway on Cluster B" }
    "mirror/eks/aws-load-balancer-controller"      = { description = "AWS Load Balancer Controller — required for the gateway's internal NLB" }
    "mirror/jetstack/cert-manager-controller"      = { description = "cert-manager controller" }
    "mirror/jetstack/cert-manager-cainjector"      = { description = "cert-manager cainjector" }
    "mirror/jetstack/cert-manager-webhook"         = { description = "cert-manager webhook" }
    "mirror/jetstack/cert-manager-startupapicheck" = { description = "cert-manager startupapicheck" }
    "charts/alloy"                                 = { description = "Grafana Alloy OCI Helm chart" }
    "charts/aws-load-balancer-controller"          = { description = "AWS Load Balancer Controller OCI Helm chart" }
    "charts/cert-manager"                          = { description = "cert-manager OCI Helm chart" }
  }
}

variable "ecr_force_delete" {
  description = "Let `terraform destroy` remove ECR repositories that still hold images. true is appropriate for a cost-capped lab that is torn down nightly."
  type        = bool
  default     = true
}

variable "enable_ecr_enhanced_scanning" {
  description = "Enable Amazon Inspector enhanced (continuous) scanning registry-wide. Billed per scan."
  type        = bool
  default     = false
}

variable "ci_push_role_arns" {
  description = "IAM roles (typically the GitHub Actions OIDC role) granted push access to ECR via repository policy."
  type        = list(string)
  default     = []
}
