###############################################################################
# modules/vpc — outputs
#
# These are the contract other modules consume. Keep them stable: modules/eks
# and modules/security are wired entirely from this surface.
###############################################################################

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN of the VPC."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "Primary IPv4 CIDR of the VPC. Consumed by modules/security to build the peering routes and the OTLP security-group rules."
  value       = aws_vpc.this.cidr_block
}

output "name" {
  description = "Logical name of this VPC."
  value       = var.name
}

output "azs" {
  description = "Availability Zones this VPC spans."
  value       = var.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered by AZ. For internet-facing load balancers and NAT only."
  value       = [for az in var.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered by AZ. EKS control-plane ENIs and all worker nodes are placed here."
  value       = [for az in var.azs : aws_subnet.private[az].id]
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDRs, ordered by AZ."
  value       = [for az in var.azs : aws_subnet.private[az].cidr_block]
}

output "public_route_table_id" {
  description = "ID of the shared public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Private route table IDs (one per AZ). modules/security injects the cross-VPC peering routes into these."
  value       = [for az in var.azs : aws_route_table.private[az].id]
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs."
  value       = aws_nat_gateway.this[*].id
}

output "nat_public_ips" {
  description = "Elastic IPs of the NAT gateways. Useful when allow-listing this cluster's egress with a third party."
  value       = aws_eip.nat[*].public_ip
}

output "default_security_group_id" {
  description = "ID of the locked-down default security group (all rules stripped). Nothing should ever attach to it."
  value       = aws_default_security_group.this.id
}

output "flow_log_group_name" {
  description = "CloudWatch Logs group receiving VPC Flow Logs, or null when disabled."
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : null
}
