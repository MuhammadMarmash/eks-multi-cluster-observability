###############################################################################
# modules/eks — managed node group
#
# Nodes are launched from an explicit launch template so that we control the
# things EKS's default template leaves open: IMDSv2 enforcement, EBS
# encryption, gp3 volumes, detailed monitoring, and — critically — the
# security groups bound to each node ENI (that is how the cross-VPC OTLP SGs
# get attached).
#
# The launch template deliberately sets NO image_id and NO user_data: leaving
# them empty lets EKS inject the correct EKS-optimized AMI for
# var.node_ami_type and generate the matching bootstrap (nodeadm on AL2023),
# so node-group version upgrades stay a one-line change.
###############################################################################

resource "aws_launch_template" "node" {
  name_prefix = "lt-${var.cluster_name}-${var.node_group_name}-"
  description = "Managed node group launch template for ${var.cluster_name}"

  vpc_security_group_ids = concat(
    # The EKS-managed cluster security group. Once a launch template specifies
    # security groups, EKS stops attaching this automatically — omitting it
    # would break kubelet <-> control plane traffic.
    [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id],
    [aws_security_group.node.id],
    var.additional_node_security_group_ids,
  )

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.node_disk_size_gb
      volume_type = "gp3"
      iops        = 3000
      throughput  = 125

      # Encryption at rest for everything that lands on the node: container
      # layers, emptyDir volumes, and any spilled observability data.
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only — blocks SSRF-style credential theft
    http_put_response_hop_limit = var.metadata_http_put_response_hop_limit
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { "Name" = "node-${var.cluster_name}-${var.node_group_name}" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { "Name" = "vol-${var.cluster_name}-${var.node_group_name}" })
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = merge(local.tags, { "Name" = "eni-${var.cluster_name}-${var.node_group_name}" })
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# Node-to-node security group. EKS's own cluster SG already permits all
# intra-cluster traffic; this one exists so that module consumers have a stable
# handle to reference from other security groups (e.g. an ALB, or the peer VPC).
resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node-sg"
  description = "Shared security group for ${var.cluster_name} worker nodes"
  vpc_id      = var.vpc_id

  tags = merge(
    local.tags,
    {
      "Name" = "${var.cluster_name}-node-sg"
      # Required so the AWS Load Balancer Controller can auto-discover the
      # node SG when it manages target groups.
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    },
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id            = aws_security_group.node.id
  description                  = "Node to node, all ports"
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "Node egress (NAT / VPC endpoints)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-${var.node_group_name}"
  node_role_arn   = aws_iam_role.node.arn

  # EKS NODES LIVE IN PRIVATE SUBNETS — no public IP, no inbound internet path.
  subnet_ids = var.private_subnet_ids

  ami_type       = var.node_ami_type
  capacity_type  = var.node_capacity_type
  instance_types = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    # Day 2: this is the knob that makes node-group upgrades a rolling,
    # zero-downtime operation. EKS cordons, drains (honouring PDBs) and
    # replaces at most this share of the group at a time.
    max_unavailable_percentage = var.node_max_unavailable_percentage
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  labels = var.node_labels

  dynamic "taint" {
    for_each = var.node_taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(local.tags, { "Name" = "${var.cluster_name}-${var.node_group_name}" })

  lifecycle {
    # Hand desired_size over to the autoscaler (Karpenter / cluster-autoscaler)
    # after creation so Terraform does not fight it on every apply.
    ignore_changes = [scaling_config[0].desired_size]

    create_before_destroy = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,

    # The CNI and kube-proxy must exist before the first node registers,
    # otherwise nodes come up NotReady and the node group creation times out.
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]

  timeouts {
    create = "30m"
    update = "60m"
    delete = "30m"
  }
}
