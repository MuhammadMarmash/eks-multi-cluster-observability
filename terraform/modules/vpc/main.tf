###############################################################################
# modules/vpc
#
# A public/private VPC purpose-built for a single EKS cluster. Instantiated
# twice: vpc-workload (Cluster A) and vpc-observability (Cluster B).
#
# Why two VPCs rather than one — blast radius and VPC CNI IP exhaustion:
#   docs/adr/0001-two-vpc-architecture.md
###############################################################################

locals {
  # One NAT gateway per AZ by default; collapsed to a single NAT when
  # var.single_nat_gateway is set (cost control for non-production).
  nat_gateway_count = var.single_nat_gateway ? 1 : length(var.azs)

  tags = merge(
    var.tags,
    {
      "Name"      = var.name
      "Module"    = "vpc"
      "ManagedBy" = "terraform"
    },
  )
}

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block = var.cidr_block

  # Both are required by EKS: the kubelet and the VPC CNI rely on VPC-provided
  # DNS, and internal service discovery / PrivateLink endpoints need hostnames.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { "Name" = "vpc-${var.name}" })
}

# Security hardening: the AWS-created default security group allows all
# intra-group traffic. We cannot delete it, so we strip every rule from it,
# leaving it inert. Nothing in this architecture is ever attached to it.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { "Name" = "${var.name}-default-locked-down-sg" })
}

###############################################################################
# Internet gateway + public subnets
#
# Public subnets exist ONLY for NAT gateways and internet-facing load
# balancers. No EKS node ever lands here.
###############################################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { "Name" = "igw-${var.name}" })
}

resource "aws_subnet" "public" {
  for_each = { for idx, az in var.azs : az => idx }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = var.public_subnet_cidrs[each.value]

  # Public IPs are auto-assigned so that NAT gateways and ALBs work, but note
  # that nothing self-managed is launched into these subnets.
  map_public_ip_on_launch = true

  tags = merge(
    local.tags,
    {
      "Name" = "subnet-${var.name}-public-${each.key}"
      "Tier" = "public"

      # AWS Load Balancer Controller discovery tags.
      "kubernetes.io/role/elb"                    = "1"
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    },
  )
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { "Name" = "rt-${var.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# NAT gateways
###############################################################################

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = merge(local.tags, { "Name" = "eip-${var.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[var.azs[count.index]].id

  tags = merge(local.tags, { "Name" = "nat-${var.name}-${var.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Private subnets — EKS worker nodes and Pod ENIs live here, and only here.
#
# Nodes have NO public IP and NO inbound path from the internet; egress for
# image pulls and AWS API calls is via NAT (or, when enabled, via the
# PrivateLink endpoints below).
###############################################################################

resource "aws_subnet" "private" {
  for_each = { for idx, az in var.azs : az => idx }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = var.private_subnet_cidrs[each.value]

  map_public_ip_on_launch = false

  tags = merge(
    local.tags,
    {
      "Name" = "subnet-${var.name}-private-${each.key}"
      "Tier" = "private"

      # Internal load balancers + EKS subnet discovery.
      "kubernetes.io/role/internal-elb"           = "1"
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    },
  )
}

# One route table per private subnet. This is required (rather than a single
# shared table) so that each AZ egresses through its *own* NAT gateway in the
# HA configuration, avoiding cross-AZ data-transfer charges and cross-AZ
# failure coupling. modules/security also injects the VPC-peering route into
# each of these tables.
resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { "Name" = "rt-${var.name}-private-${each.key}" })
}

resource "aws_route" "private_nat" {
  for_each = aws_subnet.private

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"

  # index(azs, az) picks this AZ's NAT gateway; with a single NAT gateway every
  # table points at index 0.
  nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[index(var.azs, each.key)].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

###############################################################################
# VPC endpoints
###############################################################################

# S3 gateway endpoint: free, and it keeps the LGTM stack's object-storage
# traffic (Loki chunks, Mimir blocks, Tempo traces) on the AWS backbone instead
# of paying NAT data-processing charges for every write.
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_gateway_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [for rt in aws_route_table.private : rt.id],
    [aws_route_table.public.id],
  )

  tags = merge(local.tags, { "Name" = "vpce-${var.name}-s3" })
}

resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_interface_endpoints ? 1 : 0

  name        = "${var.name}-vpc-endpoints-sg"
  description = "HTTPS from within the VPC to interface (PrivateLink) endpoints"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, { "Name" = "${var.name}-vpc-endpoints-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  count = var.enable_interface_endpoints ? 1 : 0

  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "HTTPS from the VPC CIDR only"
  cidr_ipv4         = aws_vpc.this.cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { "Name" = "vpce-${var.name}-${each.key}" })
}

###############################################################################
# Flow logs
###############################################################################

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days

  tags = merge(local.tags, { "Name" = "log-${var.name}-flow-logs" })
}

data "aws_iam_policy_document" "flow_logs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    # Confused-deputy protection: only this account's flow logs may assume it.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "role-${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role.json

  tags = local.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "vpc-flow-logs-write"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60

  tags = merge(local.tags, { "Name" = "flowlog-${var.name}" })
}
