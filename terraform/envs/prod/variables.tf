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

    m7i-flex.large (2 vCPU / 8 GiB). This is the type the platform has actually
    been deployed and verified on, and it is chosen for two reasons that pull
    the same way.

    ACCOUNT CONSTRAINT. An AWS account on the Free Plan rejects RunInstances for
    any type that is not free-tier-eligible — t3.medium and t3.large among them.
    The failure gives nothing away: the node group sits in CREATING for the full
    30-minute timeout, health.issues stays empty, no Auto Scaling group is ever
    created, and the reason appears only in CloudTrail. Check what an account
    permits with:

      aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true

    ALLOCATABLE MEMORY. EKS reserves `255Mi + 11Mi * max_pods` per node, and
    prefix delegation puts max_pods at 110 — so kube-reserved is 1465Mi per node
    REGARDLESS of instance size. On a 4 GiB t3.medium that is 36% of memory,
    leaving ~2.37 GiB; on this 8 GiB type it is 18%, leaving ~6.37 GiB. Two of
    these therefore give more allocatable memory than three t3.medium, for less
    money.
  EOT
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_desired_size" {
  description = <<-EOT
    Desired node count for Cluster A (workload).

    Two. At 6.37 GiB allocatable per m7i-flex.large that is 12.75 GiB for the
    workload application's sixteen services plus the Alloy DaemonSet, which the
    deployed platform ran at comfortable headroom.
  EOT
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count for Cluster A. Must not drop below what the workload application needs to schedule."
  type        = number
  default     = 2
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

    Two. The LGTM stack requests 1.50 vCPU and 3.34 GiB; with the gateway,
    cert-manager and the load balancer controller that lands near 60% CPU and
    42% memory of two m7i-flex.large nodes.

    Three t3.medium would give LESS allocatable memory than two of these, and
    cost more — see node_instance_types.
  EOT
  type        = number
  default     = 2
}

variable "observability_node_min_size" {
  description = "Minimum node count for Cluster B. Must not drop below what the LGTM stack needs to schedule."
  type        = number
  default     = 2
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
  description = "ECR repositories to create. Defaults cover every image and chart scripts/mirror-images.sh pushes, and nothing else."
  type = map(object({
    description          = optional(string, "")
    keep_last_n_images   = optional(number, 30)
    untagged_expiry_days = optional(number, 7)
    protected_tag_prefix = optional(string, "v")
  }))
  default = {

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
    "mirror/postgres"           = { description = "PostgreSQL, the demo product-catalog backing store" }
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
