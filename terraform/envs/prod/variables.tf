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
  default     = "https://github.com/MuhammadMarmash/eks-multi-cluster-observability"
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

    t3.medium (2 vCPU / 4 GiB). Note that t3.medium and t3.large have the SAME
    2 vCPU — the difference is memory only, so downsizing costs RAM and nothing
    else.

    The memory cost is larger than the raw numbers suggest. EKS reserves
    `255Mi + 11Mi * max_pods`, and prefix delegation raises max_pods to 110, so
    kube-reserved is 1465Mi PER NODE regardless of instance size. On a t3.large
    that is 18% of memory; on a t3.medium it is 36%. Real allocatable is
    ~2.37 GiB per t3.medium node, not 4.

    That is why the observability node group runs three nodes rather than two —
    see observability_node_desired_size.
  EOT
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = <<-EOT
    Desired node count for Cluster A (workload).

    Three, matching Cluster B. Two t3.medium nodes give 4.75 GiB of ALLOCATABLE
    memory once kube-reserved is taken out, and the Online Boutique's eleven
    services plus the Alloy DaemonSet do not leave enough margin in that for a
    node to go away.
  EOT
  type        = number
  default     = 3
}

variable "node_min_size" {
  description = "Minimum node count for Cluster A. Must not drop below what the Boutique needs to schedule."
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "Maximum node count per cluster."
  type        = number
  default     = 6
}

# --- Observability node group -------------------------------------------------
#
# Cluster B carries the whole LGTM stack plus the telemetry gateway, and its
# memory demand is far higher than Cluster A's. These override the shared node
# counts for that cluster only.

variable "observability_node_desired_size" {
  description = <<-EOT
    Desired node count for Cluster B.

    Three, not two. Two t3.medium nodes give 4.75 GiB of ALLOCATABLE memory once
    kube-reserved is taken out, and the LGTM stack plus the gateway, cert-manager
    and the load balancer controller do not fit in that. Three gives 7.12 GiB.

    Three t3.medium nodes also cost less than the two t3.large they replace.
  EOT
  type        = number
  default     = 3
}

variable "observability_node_min_size" {
  description = "Minimum node count for Cluster B. Must not drop below what the LGTM stack needs to schedule."
  type        = number
  default     = 3
}

variable "observability_node_max_size" {
  description = "Maximum node count for Cluster B."
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

    # LGTM backends, Grafana and metrics-server.
    "mirror/grafana/mimir"                 = { description = "Grafana Mimir, the metrics backend" }
    "mirror/grafana/loki"                  = { description = "Grafana Loki, the logs backend" }
    "mirror/grafana/tempo"                 = { description = "Grafana Tempo, the traces backend" }
    "mirror/grafana/grafana"               = { description = "Grafana, the single pane of glass" }
    "mirror/grafana/rollout-operator"      = { description = "Rollout operator, required by mimir-distributed to roll StatefulSets" }
    "mirror/nginxinc/nginx-unprivileged"   = { description = "nginx, the Mimir and Loki chart gateways" }
    "mirror/metrics-server/metrics-server" = { description = "metrics-server, the resource metrics API every HPA reads" }
    "charts/mimir-distributed"             = { description = "Mimir OCI Helm chart" }
    "charts/loki"                          = { description = "Loki OCI Helm chart" }
    "charts/tempo"                         = { description = "Tempo OCI Helm chart, single-binary" }
    "charts/grafana"                       = { description = "Grafana OCI Helm chart" }
    "charts/metrics-server"                = { description = "metrics-server OCI Helm chart" }

    # The workload application on Cluster A (ADR 0009). All fifteen demo
    # services share one repository and differ only by tag, so this is three
    # repositories rather than seventeen.
    "mirror/otel-demo"          = { description = "OpenTelemetry demo services, one tag per component" }
    "mirror/open-feature/flagd" = { description = "flagd, the demo's feature-flag service" }
    "mirror/valkey-io/valkey"   = { description = "Valkey, the demo's cart backing store" }
    "charts/opentelemetry-demo" = { description = "OpenTelemetry demo OCI Helm chart" }
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

# --- LGTM storage ------------------------------------------------------------------

variable "lgtm_namespace" {
  description = <<-EOT
    Namespace the LGTM stack runs in on Cluster B. Every IRSA trust policy for
    Loki, Mimir and Tempo is pinned to this namespace, so changing it here
    without changing where the Helm releases land breaks every S3 credential at
    once — and the symptom is an opaque AccessDenied on first write.

    Deliberately NOT the telemetry namespace that holds the gateway: an IRSA
    trust policy is scoped to namespace/ServiceAccount, so sharing a namespace
    would widen who can assume these roles.
  EOT
  type        = string
  default     = "lgtm"
}
