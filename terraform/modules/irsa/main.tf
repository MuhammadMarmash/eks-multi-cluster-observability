###############################################################################
# modules/irsa
#
# One IAM role assumable by exactly one Kubernetes ServiceAccount, via the
# cluster's OIDC provider. The trust policy pins BOTH the `sub` (exact
# namespace/ServiceAccount) and the `aud` (sts.amazonaws.com) condition;
# omitting either is the classic IRSA misconfiguration.
#   docs/adr/0004-cluster-security-posture.md
#
# The trust policy is built with jsonencode() rather than
# data.aws_iam_policy_document — unlike modules/eks — so that the document is
# a plain string the module can assert on under `terraform test` with
# mock_provider, where every AWS data source returns a generated value.
###############################################################################

locals {
  tags = merge(
    var.tags,
    {
      "Module"    = "irsa"
      "ManagedBy" = "terraform"
    },
  )

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${var.oidc_provider_host}:sub" = "system:serviceaccount:${var.namespace}:${var.service_account}"
            "${var.oidc_provider_host}:aud" = "sts.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  description        = var.description != "" ? var.description : "IRSA role for ${var.namespace}/${var.service_account}"
  assume_role_policy = local.assume_role_policy

  tags = merge(local.tags, {
    "Name"           = var.role_name
    "ServiceAccount" = "${var.namespace}/${var.service_account}"
  })
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  count = var.inline_policy_json == null ? 0 : 1

  name   = "${var.role_name}-inline"
  role   = aws_iam_role.this.id
  policy = var.inline_policy_json
}
