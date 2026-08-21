###############################################################################
# modules/dns-private-zone — outputs
###############################################################################

output "zone_id" {
  description = "Hosted zone ID. Pass to whichever module creates records in the zone."
  value       = aws_route53_zone.this.zone_id
}

output "zone_name" {
  description = "Zone name, without a trailing dot."
  value       = var.zone_name
}

output "associated_vpc_ids" {
  description = "Every VPC that can resolve names in this zone, primary first."
  value       = concat([var.primary_vpc_id], var.additional_vpc_ids)
}
