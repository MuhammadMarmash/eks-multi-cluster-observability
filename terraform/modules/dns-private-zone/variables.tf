###############################################################################
# modules/dns-private-zone — input variables
###############################################################################

variable "zone_name" {
  description = <<-EOT
    Name of the private hosted zone, e.g. "observability.internal". Use a
    reserved-looking suffix such as .internal: a name that could plausibly
    exist in public DNS will resolve publicly from anywhere the zone is not
    associated, which fails open rather than closed.
  EOT
  type        = string

  validation {
    condition     = endswith(var.zone_name, ".internal") || endswith(var.zone_name, ".local")
    error_message = "zone_name must end in .internal or .local so it can never collide with a public name."
  }
}

variable "primary_vpc_id" {
  description = "VPC that owns the zone. Conventionally the VPC the records point into — here, the observability VPC."
  type        = string
}

variable "additional_vpc_ids" {
  description = <<-EOT
    Every other VPC that must be able to resolve names in this zone. The
    workload VPC belongs here: without its association, a query from Cluster A
    leaks past the VPC resolver and returns NXDOMAIN.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
