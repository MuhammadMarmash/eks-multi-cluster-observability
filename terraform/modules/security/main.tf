###############################################################################
# modules/security
#
# The only sanctioned coupling between the two VPCs: the peering connection,
# the private-subnet routes, and the OTLP security groups.
#
# Why peering rather than PrivateLink or public endpoints, and the three-layer
# security model it rests on:
#   docs/adr/0002-cross-vpc-telemetry-transport.md
###############################################################################

locals {
  tags = merge(
    var.tags,
    {
      "Module"    = "security"
      "ManagedBy" = "terraform"
    },
  )

  # Keyed by port so that adding/removing a port never re-creates the others.
  otlp_rules = {
    for p in var.otlp_ports : tostring(p) => {
      port        = p
      description = p == 4317 ? "OTLP/gRPC from workload VPC" : (p == 4318 ? "OTLP/HTTP from workload VPC" : "OTLP from workload VPC")
    }
  }
}

###############################################################################
# VPC peering connection
###############################################################################

resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.workload_vpc_id      # requester, Cluster A
  peer_vpc_id = var.observability_vpc_id # accepter,  Cluster B

  # peer_region is deliberately unset. AWS refuses `peer_region` together with
  # `auto_accept = true`, and both VPCs are in the same Region anyway, so the
  # peer Region is implied. Setting it would force manual acceptance.
  auto_accept = var.auto_accept_peering

  tags = merge(local.tags, {
    "Name" = "pcx-${var.name_prefix}-workload-to-observability"
    "Side" = "requester"
  })
}

# Allow each side to resolve the other's private Route 53 / VPC DNS records to
# private IPs. Without this, an in-cluster DNS name that resolves to a private
# endpoint on the peer resolves to a public address and the traffic never uses
# the peering link.
resource "aws_vpc_peering_connection_options" "this" {
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  # The options can only be set once the connection is in `active` state, which
  # auto_accept guarantees within the same account.
  depends_on = [aws_vpc_peering_connection.this]
}

###############################################################################
# Routes — private subnets only, in both directions.
#
# count (not for_each) is used deliberately: the route table IDs are unknown at
# plan time on a green-field apply, and for_each keys must be known during
# plan. The list *lengths* are known, so count plans cleanly.
###############################################################################

resource "aws_route" "workload_to_observability" {
  count = length(var.workload_private_route_table_ids)

  route_table_id            = var.workload_private_route_table_ids[count.index]
  destination_cidr_block    = var.observability_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

resource "aws_route" "observability_to_workload" {
  count = length(var.observability_private_route_table_ids)

  route_table_id            = var.observability_private_route_table_ids[count.index]
  destination_cidr_block    = var.workload_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

###############################################################################
# Security group — OBSERVABILITY side (ingress)
#
# Attach this to the Cluster B nodes (done by the root module via the EKS
# module's additional_node_security_group_ids input). It is what actually lets
# the OTLP Gateway Collector / LGTM ingress receive cross-VPC telemetry.
###############################################################################

resource "aws_security_group" "otlp_ingress" {
  name        = "${var.name_prefix}-otlp-ingress-sg"
  description = "Accept OTLP telemetry from the workload VPC over the peering link"
  vpc_id      = var.observability_vpc_id

  tags = merge(local.tags, {
    "Name"    = "${var.name_prefix}-otlp-ingress-sg"
    "Purpose" = "cross-vpc-telemetry"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# 4317 (gRPC) and 4318 (HTTP), sourced from the workload VPC CIDR only.
# Note that a security group cannot reference a peer VPC's security group
# across a peering connection unless the peer is in the same Region and the
# reference is explicitly enabled — CIDR-scoping is the portable, auditable
# choice here and is what the design calls for.
resource "aws_vpc_security_group_ingress_rule" "otlp" {
  for_each = local.otlp_rules

  security_group_id = aws_security_group.otlp_ingress.id
  description       = each.value.description
  cidr_ipv4         = var.workload_vpc_cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"

  tags = merge(local.tags, { "Name" = "otlp-${each.key}-from-workload" })
}

# The load balancer and the pods behind it BOTH carry this group: the root
# module attaches it to the Cluster B nodes, and the gateway Service names it in
# `aws-load-balancer-security-groups`. The rules above admit the workload VPC to
# the load balancer, but nothing admits the LOAD BALANCER to the targets — so
# even the TCP health check is dropped, every target reports
# Target.FailedHealthChecks, and the NLB refuses to route. From the client the
# symptom is an i/o timeout, which looks like a routing or peering fault.
#
# A self-referencing rule is exactly right here rather than a CIDR: it grants
# only what already carries this group, and it stays correct if the load
# balancer's addresses change.
resource "aws_vpc_security_group_ingress_rule" "otlp_from_load_balancer" {
  for_each = local.otlp_rules

  security_group_id            = aws_security_group.otlp_ingress.id
  description                  = "${each.value.description} via the internal load balancer"
  referenced_security_group_id = aws_security_group.otlp_ingress.id
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"

  tags = merge(local.tags, { "Name" = "otlp-${each.key}-from-nlb" })
}

# The other half. The load balancer carries this group too, so it needs egress
# to the targets; without it the health check never leaves the load balancer.
resource "aws_vpc_security_group_egress_rule" "otlp_to_targets" {
  for_each = local.otlp_rules

  security_group_id            = aws_security_group.otlp_ingress.id
  description                  = "Load balancer to gateway targets on ${each.key}"
  referenced_security_group_id = aws_security_group.otlp_ingress.id
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"

  tags = merge(local.tags, { "Name" = "otlp-${each.key}-to-targets" })
}

resource "aws_vpc_security_group_ingress_rule" "extra" {
  for_each = var.extra_observability_ingress

  security_group_id = aws_security_group.otlp_ingress.id
  description       = each.value.description
  cidr_ipv4         = var.workload_vpc_cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = each.value.protocol

  tags = merge(local.tags, { "Name" = "extra-${each.key}-from-workload" })
}

# Egress is intentionally NOT wide open on this SG. Nodes get their general
# egress from the EKS-managed cluster security group; this SG exists purely to
# express "telemetry may enter here".
resource "aws_vpc_security_group_egress_rule" "otlp_ingress_return" {
  security_group_id = aws_security_group.otlp_ingress.id
  description       = "Return traffic to the workload VPC"
  cidr_ipv4         = var.workload_vpc_cidr
  ip_protocol       = "-1"

  tags = merge(local.tags, { "Name" = "return-to-workload" })
}

###############################################################################
# Security group — WORKLOAD side (egress)
#
# Attach this to the Cluster A nodes. It scopes what the OpenTelemetry
# Collector / Grafana Alloy agents on Cluster A are allowed to reach in the
# observability VPC: the OTLP ports, and nothing else.
###############################################################################

resource "aws_security_group" "otlp_egress" {
  name = "${var.name_prefix}-otlp-egress-sg"
  # No apostrophe. EC2 restricts security group descriptions to
  # `a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*`, which does not include `'`.
  description = "Telemetry agents on the workload cluster may reach the observability VPC on OTLP ports"
  vpc_id      = var.workload_vpc_id

  tags = merge(local.tags, {
    "Name"    = "${var.name_prefix}-otlp-egress-sg"
    "Purpose" = "cross-vpc-telemetry"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "otlp" {
  for_each = local.otlp_rules

  security_group_id = aws_security_group.otlp_egress.id
  description       = "OTLP to the observability VPC on ${each.key}"
  cidr_ipv4         = var.observability_vpc_cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"

  tags = merge(local.tags, { "Name" = "otlp-${each.key}-to-observability" })
}

resource "aws_vpc_security_group_egress_rule" "extra" {
  for_each = var.extra_observability_ingress

  security_group_id = aws_security_group.otlp_egress.id
  description       = "${each.value.description} (egress side)"
  cidr_ipv4         = var.observability_vpc_cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = each.value.protocol

  tags = merge(local.tags, { "Name" = "extra-${each.key}-to-observability" })
}
