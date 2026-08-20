###############################################################################
# modules/security — outputs
###############################################################################

output "peering_connection_id" {
  description = "ID of the VPC peering connection between the workload and observability VPCs."
  value       = aws_vpc_peering_connection.this.id
}

output "peering_connection_status" {
  description = "Accept status of the peering connection (should be \"active\")."
  value       = aws_vpc_peering_connection.this.accept_status
}

output "otlp_ingress_security_group_id" {
  description = "Security group in the OBSERVABILITY VPC that accepts OTLP 4317/4318 from the workload CIDR. Attach to Cluster B nodes."
  value       = aws_security_group.otlp_ingress.id
}

output "otlp_egress_security_group_id" {
  description = "Security group in the WORKLOAD VPC that permits egress to the observability CIDR on OTLP ports. Attach to Cluster A nodes."
  value       = aws_security_group.otlp_egress.id
}

output "otlp_ports" {
  description = "OTLP ports opened across the peering link."
  value       = var.otlp_ports
}
