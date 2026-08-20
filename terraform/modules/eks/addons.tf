###############################################################################
# modules/eks — EKS managed add-ons
#
# Ordering matters and is enforced with depends_on:
#
#   cluster
#     -> vpc-cni + kube-proxy      (must exist before the first node registers,
#                                   or nodes never reach Ready)
#       -> managed node group
#         -> coredns + aws-ebs-csi-driver
#                                  (both schedule real Pods, so they need
#                                   capacity to land on)
#
# Versions resolve to the EKS default for the cluster's Kubernetes version
# unless pinned in var.addon_versions — pin them in production so an add-on
# never moves underneath you during an unrelated apply.
###############################################################################

locals {
  addon_names = ["vpc-cni", "kube-proxy", "coredns", "aws-ebs-csi-driver"]
}

data "aws_eks_addon_version" "this" {
  for_each = toset(local.addon_names)

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

# --- Networking: installed BEFORE the node group ------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"
  addon_version = try(
    var.addon_versions["vpc-cni"],
    data.aws_eks_addon_version.this["vpc-cni"].version,
  )

  # IRSA, not the node role: the CNI's ENI/IP mutation rights stay bound to the
  # aws-node ServiceAccount.
  service_account_role_arn = aws_iam_role.irsa["vpc_cni"].arn

  # Set ENABLE_PREFIX_DELEGATION=true here to raise Pod density per node. This
  # is safe *because* the private subnets are /20s — see
  # docs/adr/0001-two-vpc-architecture.md.
  configuration_values = var.vpc_cni_configuration

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(local.tags, { "Name" = "${var.cluster_name}-vpc-cni" })

  depends_on = [aws_iam_role_policy_attachment.irsa]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"
  addon_version = try(
    var.addon_versions["kube-proxy"],
    data.aws_eks_addon_version.this["kube-proxy"].version,
  )

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(local.tags, { "Name" = "${var.cluster_name}-kube-proxy" })
}

# --- Workload add-ons: installed AFTER there are nodes to schedule on ---------

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"
  addon_version = try(
    var.addon_versions["coredns"],
    data.aws_eks_addon_version.this["coredns"].version,
  )

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(local.tags, { "Name" = "${var.cluster_name}-coredns" })

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "aws-ebs-csi-driver"
  addon_version = try(
    var.addon_versions["aws-ebs-csi-driver"],
    data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version,
  )

  # Needed by any StatefulSet that still wants block storage — Grafana's SQLite
  # volume, Loki/Mimir/Tempo write-ahead logs and ingester scratch space. Note
  # that DURABLE observability data goes to S3 via IRSA, not to these volumes.
  service_account_role_arn = aws_iam_role.irsa["ebs_csi"].arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(local.tags, { "Name" = "${var.cluster_name}-aws-ebs-csi-driver" })

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.irsa,
  ]
}
