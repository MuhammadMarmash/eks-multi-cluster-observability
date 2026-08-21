###############################################################################
# modules/dns-private-zone
#
# A Route 53 private hosted zone associated with more than one VPC. This is
# the mechanism that lets a pod in Cluster A resolve a name that points into
# Cluster B, with no CoreDNS configuration on either cluster: the query
# forwards to the VPC resolver, which is authoritative for this zone because
# the querying VPC is associated with it.
#
#   docs/adr/0007-cross-cluster-name-resolution.md
###############################################################################

locals {
  tags = merge(
    var.tags,
    {
      "Module"    = "dns-private-zone"
      "ManagedBy" = "terraform"
    },
  )
}

resource "aws_route53_zone" "this" {
  name          = var.zone_name
  comment       = "Private zone for cross-cluster service discovery"
  force_destroy = false

  vpc {
    vpc_id = var.primary_vpc_id
  }

  # Associations made by aws_route53_zone_association are invisible to this
  # resource's own vpc blocks. Without this, every plan would try to remove
  # them and the two resources would fight forever. This is the documented
  # pattern for a multi-VPC private zone.
  lifecycle {
    ignore_changes = [vpc]
  }

  tags = merge(local.tags, { "Name" = var.zone_name })
}

resource "aws_route53_zone_association" "additional" {
  for_each = toset(var.additional_vpc_ids)

  zone_id = aws_route53_zone.this.zone_id
  vpc_id  = each.value
}
