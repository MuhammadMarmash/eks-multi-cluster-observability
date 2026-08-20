###############################################################################
# modules/eks — IAM
#
# Two distinct roles, plus IRSA roles for the add-ons that need AWS APIs.
# Least privilege rule of thumb applied throughout: the node role carries only
# what the kubelet itself needs; anything a *Pod* needs comes from IRSA.
###############################################################################

# --- Cluster (control plane) role ---------------------------------------------

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name                  = "role-${var.cluster_name}-cluster"
  description           = "EKS control plane role for ${var.cluster_name}"
  assume_role_policy    = data.aws_iam_policy_document.cluster_assume_role.json
  force_detach_policies = true

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  # Only what a standard (non-Auto-Mode) control plane needs. The Auto Mode
  # policies (AmazonEKSComputePolicy, ...BlockStoragePolicy, ...NetworkingPolicy,
  # ...LoadBalancingPolicy) are intentionally NOT attached: this cluster manages
  # its own node groups and add-ons, so those grants would be dead privilege.
  for_each = {
    eks_cluster       = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
    vpc_resource_ctrl = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSVPCResourceController"
  }

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# --- Node role -----------------------------------------------------------------
#
# Note what is deliberately ABSENT: AmazonEKS_CNI_Policy. The VPC CNI gets its
# ENI/IP permissions through its own IRSA role (see irsa.tf) so that a
# compromised Pod that somehow reaches the node role cannot manipulate ENIs.

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name                  = "role-${var.cluster_name}-node"
  description           = "EKS managed node group role for ${var.cluster_name}"
  assume_role_policy    = data.aws_iam_policy_document.node_assume_role.json
  force_detach_policies = true

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = merge(
    {
      worker_node = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
      ecr_read    = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"

      # SSM Session Manager instead of SSH: no port 22, no key pairs, no bastion,
      # and every session is logged in CloudTrail.
      ssm_core = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
    },
    var.node_additional_policy_arns,
  )

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# Nodes must be able to write their own log streams for the container runtime.
data "aws_iam_policy_document" "node_cloudwatch" {
  statement {
    sid    = "NodeLogWrite"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/*"]
  }
}

resource "aws_iam_role_policy" "node_cloudwatch" {
  name   = "node-log-write"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node_cloudwatch.json
}
