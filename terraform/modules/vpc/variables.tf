###############################################################################
# modules/vpc — input variables
###############################################################################

variable "name" {
  description = "Name of the VPC (e.g. \"workload\", \"observability\"). Used as the resource name prefix."
  type        = string
}

variable "cidr_block" {
  description = <<-EOT
    Primary IPv4 CIDR for the VPC.

    Sizing note: EKS uses the AWS VPC CNI, which assigns a *routable VPC IP to
    every Pod*, not just to every node. A /16 is deliberately used here so that
    Pod density is bounded by the instance ENI limits, never by free IPs in the
    subnet. See docs/adr/0001-two-vpc-architecture.md.
  EOT
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR block."
  }
}

variable "azs" {
  description = "Availability Zones to spread subnets across. Length must match the subnet CIDR lists."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least two Availability Zones are required for a production EKS control plane."
  }
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs, one per AZ (index-aligned with var.azs). Hosts NAT gateways and internet-facing load balancers only."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs, one per AZ (index-aligned with var.azs). All EKS worker nodes and Pod ENIs live here."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = <<-EOT
    true  -> one NAT gateway in the first AZ (cheapest; a single AZ failure cuts
             egress for the whole VPC).
    false -> one NAT gateway per AZ (production HA; ~$32/month each plus data
             processing).
  EOT
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Ship VPC Flow Logs (REJECT + ACCEPT) to CloudWatch Logs. Required for network forensics and for debugging cross-VPC peering traffic."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC Flow Logs, in days."
  type        = number
  default     = 30
}

variable "enable_s3_gateway_endpoint" {
  description = "Create the S3 gateway VPC endpoint. Free, and keeps Loki/Mimir/Tempo -> S3 traffic off the NAT gateway (a large cost and latency win)."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = <<-EOT
    Create interface (PrivateLink) endpoints for ECR, CloudWatch Logs, STS, EC2
    and Secrets Manager. This lets nodes pull images and assume IRSA roles with
    no NAT hop at all, but each endpoint bills per-AZ-hour. Off by default to
    respect the project cost cap.
  EOT
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  description = "Service short-names for the interface endpoints created when enable_interface_endpoints is true."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "logs", "sts", "ec2", "secretsmanager", "elasticloadbalancing"]
}

variable "cluster_name" {
  description = "Name of the EKS cluster that will run in this VPC. Used for the kubernetes.io/cluster/<name> subnet discovery tags."
  type        = string
}

variable "tags" {
  description = "Tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
