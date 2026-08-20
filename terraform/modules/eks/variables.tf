###############################################################################
# modules/eks — input variables
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster. Must be unique per Region and is used as the prefix for every dependent resource."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the control plane. Node groups follow the control plane version unless pinned."
  type        = string
  default     = "1.34"
}

variable "vpc_id" {
  description = "VPC the cluster is created in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs. The control-plane cross-account ENIs AND every managed node land here — no node is ever placed in a public subnet."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two Availability Zones."
  }
}

# --- API server endpoint access ----------------------------------------------

variable "endpoint_private_access" {
  description = "Enable the private API server endpoint (reachable from inside the VPC and, via peering, from the peer VPC)."
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = <<-EOT
    Enable the public API server endpoint. Kept true so CI runners and
    operators can reach the cluster without a bastion/VPN, but it MUST be
    paired with a non-default public_access_cidrs allow-list. Set to false once
    a VPN or SSM-based bastion is in place.
  EOT
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs permitted to reach the public API endpoint. Leaving this at 0.0.0.0/0 is flagged by the validation below in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- Control plane logging & encryption ---------------------------------------

variable "enabled_cluster_log_types" {
  description = "Control-plane log types shipped to CloudWatch. 'audit' and 'authenticator' are non-negotiable for a security audit trail."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_log_retention_days" {
  description = "Retention for the control-plane CloudWatch log group."
  type        = number
  default     = 30
}

variable "kms_key_deletion_window_days" {
  description = "Waiting period before the cluster's secrets-encryption KMS key is deleted."
  type        = number
  default     = 30
}

# --- Access management ---------------------------------------------------------

variable "authentication_mode" {
  description = "EKS access mode. API_AND_CONFIG_MAP allows IAM-native access entries while remaining compatible with any legacy aws-auth ConfigMap tooling."
  type        = string
  default     = "API_AND_CONFIG_MAP"

  validation {
    condition     = contains(["CONFIG_MAP", "API", "API_AND_CONFIG_MAP"], var.authentication_mode)
    error_message = "authentication_mode must be one of CONFIG_MAP, API, API_AND_CONFIG_MAP."
  }
}

variable "bootstrap_cluster_creator_admin_permissions" {
  description = "Grant the identity running terraform apply cluster-admin. Useful for bootstrap; revoke and replace with explicit access entries afterwards."
  type        = bool
  default     = true
}

variable "access_entries" {
  description = <<-EOT
    IAM principals granted access to the cluster API, keyed by a stable name.
    Example:
      platform_admins = {
        principal_arn = "arn:aws:iam::111122223333:role/PlatformAdmin"
        policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope  = { type = "cluster" }
      }
  EOT
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string), [])
    policy_arn        = optional(string)
    access_scope = optional(object({
      type       = optional(string, "cluster")
      namespaces = optional(list(string))
    }), { type = "cluster" })
  }))
  default = {}
}

# --- Managed node group --------------------------------------------------------

variable "node_group_name" {
  description = "Name suffix of the managed node group."
  type        = string
  default     = "default"
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. Observability backends holding write-ahead logs should stay ON_DEMAND."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_desired_size" {
  description = "Desired node count. Ignored on subsequent applies so an autoscaler can own it (see lifecycle block)."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 6
}

variable "node_disk_size_gb" {
  description = "Root EBS volume size per node, in GiB."
  type        = number
  default     = 50
}

variable "node_ami_type" {
  description = "EKS-optimized AMI family. AL2023_x86_64_STANDARD is the current default family; use AL2023_ARM_64_STANDARD for Graviton."
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "node_labels" {
  description = "Kubernetes labels applied to the nodes in this group."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Kubernetes taints applied to the nodes in this group, keyed by a stable name."
  type = map(object({
    key    = string
    value  = optional(string)
    effect = string # NO_SCHEDULE | NO_EXECUTE | PREFER_NO_SCHEDULE
  }))
  default = {}
}

variable "node_max_unavailable_percentage" {
  description = "Percentage of nodes that may be unavailable during a rolling node-group update. Drives the Day-2 upgrade strategy."
  type        = number
  default     = 33
}

variable "additional_node_security_group_ids" {
  description = <<-EOT
    Extra security groups attached to every node ENI. This is how the
    cross-VPC OTLP security groups from modules/security are bound to the
    nodes: the egress SG on Cluster A, the ingress SG on Cluster B.
  EOT
  type        = list(string)
  default     = []
}

variable "metadata_http_put_response_hop_limit" {
  description = <<-EOT
    IMDSv2 hop limit. 1 means a container in a Pod network namespace CANNOT
    reach the instance metadata service, which forcibly closes the classic
    "pod steals the node role's credentials" escalation path and makes IRSA the
    only way for a Pod to obtain AWS credentials. Raise to 2 only if a
    third-party chart genuinely requires node-level IMDS.
  EOT
  type        = number
  default     = 1
}

variable "node_additional_policy_arns" {
  description = "Extra managed policy ARNs to attach to the node role, keyed by a stable name."
  type        = map(string)
  default     = {}
}

# --- Add-ons -------------------------------------------------------------------

variable "addon_versions" {
  description = "Pin specific add-on versions by add-on name. Any add-on left unset resolves to the default version for the cluster's Kubernetes version."
  type        = map(string)
  default     = {}
}

variable "vpc_cni_configuration" {
  description = <<-EOT
    JSON configuration for the vpc-cni add-on. ENABLE_PREFIX_DELEGATION lets a
    node allocate /28 IP prefixes instead of individual secondary IPs, raising
    Pod density per node substantially — which is exactly why the private
    subnets in modules/vpc are sized at /20.
  EOT
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
