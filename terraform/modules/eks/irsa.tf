###############################################################################
# modules/eks — IRSA roles for the add-ons
#
# Each trust policy pins BOTH the `sub` (exact namespace/ServiceAccount) and
# the `aud` (sts.amazonaws.com) condition. Omitting either is the classic IRSA
# misconfiguration — see docs/adr/0004-cluster-security-posture.md.
###############################################################################

locals {
  irsa_service_accounts = {
    vpc_cni = {
      namespace       = "kube-system"
      service_account = "aws-node"
      policy_arn      = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
      role_name       = "role-${var.cluster_name}-vpc-cni"
    }
    ebs_csi = {
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
      policy_arn      = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      role_name       = "role-${var.cluster_name}-ebs-csi"
    }
  }
}

data "aws_iam_policy_document" "irsa_assume_role" {
  for_each = local.irsa_service_accounts

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = local.irsa_service_accounts

  name               = each.value.role_name
  description        = "IRSA role for ${each.value.namespace}/${each.value.service_account} in ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role[each.key].json

  tags = merge(local.tags, {
    "Name"           = each.value.role_name
    "ServiceAccount" = "${each.value.namespace}/${each.value.service_account}"
  })
}

resource "aws_iam_role_policy_attachment" "irsa" {
  for_each = local.irsa_service_accounts

  role       = aws_iam_role.irsa[each.key].name
  policy_arn = each.value.policy_arn
}

# The EBS CSI driver must be able to use the account's EBS encryption key to
# create encrypted volumes. Scoped to grants made on behalf of EC2/EBS only.
data "aws_iam_policy_document" "ebs_csi_kms" {
  statement {
    sid    = "AllowGeneratingDataKeysForEncryptedVolumes"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ec2.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "AllowCreatingAndRevokingGrants"
    effect    = "Allow"
    actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role_policy" "ebs_csi_kms" {
  name   = "ebs-csi-kms"
  role   = aws_iam_role.irsa["ebs_csi"].id
  policy = data.aws_iam_policy_document.ebs_csi_kms.json
}
