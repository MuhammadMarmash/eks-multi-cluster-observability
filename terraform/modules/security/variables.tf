###############################################################################
# modules/security — input variables
###############################################################################

variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module."
  type        = string
  default     = "obs-platform"
}

# --- Requester side: the workload VPC (Cluster A) -----------------------------

variable "workload_vpc_id" {
  description = "VPC ID of the workload VPC (Cluster A). This side requests the peering connection."
  type        = string
}

variable "workload_vpc_cidr" {
  description = "CIDR of the workload VPC. Used as the source in the OTLP ingress rules on the observability side."
  type        = string
}

variable "workload_private_route_table_ids" {
  description = "Private route table IDs in the workload VPC. A route to the observability CIDR is added to each."
  type        = list(string)
}

# --- Accepter side: the observability VPC (Cluster B) -------------------------

variable "observability_vpc_id" {
  description = "VPC ID of the observability VPC (Cluster B). This side accepts the peering connection."
  type        = string
}

variable "observability_vpc_cidr" {
  description = "CIDR of the observability VPC. Used as the destination in the workload egress rules."
  type        = string
}

variable "observability_private_route_table_ids" {
  description = "Private route table IDs in the observability VPC. A route back to the workload CIDR is added to each."
  type        = list(string)
}

# --- Telemetry ----------------------------------------------------------------

variable "otlp_ports" {
  description = <<-EOT
    OTLP receiver ports opened across the peering link.
      4317 = OTLP/gRPC
      4318 = OTLP/HTTP
    Both are TLS-terminated at the receiving Gateway Collector; the peering link
    carries encrypted traffic, it does not replace transport security.
  EOT
  type        = list(number)
  default     = [4317, 4318]
}

variable "extra_observability_ingress" {
  description = <<-EOT
    Additional ports to open from the workload VPC to the observability VPC,
    keyed by a stable rule name. Use for pushing to Loki (3100), Mimir (8080)
    or Tempo directly if you bypass the Gateway Collector.
  EOT
  type = map(object({
    port        = number
    protocol    = optional(string, "tcp")
    description = string
  }))
  default = {}
}

variable "auto_accept_peering" {
  description = "Auto-accept the peering connection. Valid only when both VPCs are in the same AWS account and Region, which is the case here."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
