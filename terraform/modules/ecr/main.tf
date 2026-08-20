###############################################################################
# modules/ecr
#
# Private registry for both internal Docker images and OCI Helm charts.
# Nothing is pulled from a public source at deploy time.
#
# Supply-chain rationale (immutability, scan-on-push, mirroring):
#   docs/adr/0005-container-supply-chain.md
###############################################################################

locals {
  tags = merge(
    var.tags,
    {
      "Module"    = "ecr"
      "ManagedBy" = "terraform"
    },
  )
}

resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name = each.key

  # PRODUCTION STANDARD 1 — a released tag is immutable forever.
  image_tag_mutability = var.image_tag_mutability

  force_delete = var.force_delete

  image_scanning_configuration {
    # PRODUCTION STANDARD 2 — every push is CVE-scanned.
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = var.encryption_type
    kms_key         = var.encryption_type == "KMS" ? var.kms_key_arn : null
  }

  tags = merge(local.tags, {
    "Name"        = each.key
    "Description" = each.value.description
  })
}

###############################################################################
# Lifecycle policies
#
# Untagged layers are garbage from failed or superseded builds and are expired
# quickly; tagged releases are capped so storage cost stays bounded without
# deleting anything that might still be running in a cluster.
###############################################################################

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = var.repositories

  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${each.value.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = each.value.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last ${each.value.keep_last_n_images} released images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = [each.value.protected_tag_prefix]
          countType     = "imageCountMoreThan"
          countNumber   = each.value.keep_last_n_images
        }
        action = { type = "expire" }
      },
    ]
  })
}

###############################################################################
# Repository policies (cross-account / explicit principals only)
###############################################################################

data "aws_iam_policy_document" "repository" {
  count = length(var.pull_principal_arns) > 0 || length(var.push_principal_arns) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = length(var.pull_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowPull"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.pull_principal_arns
      }

      actions = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:ListImages",
      ]
    }
  }

  dynamic "statement" {
    for_each = length(var.push_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowPush"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.push_principal_arns
      }

      actions = [
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
      ]
    }
  }

  # Defence in depth: refuse any request that did not arrive over TLS.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["ecr:*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_ecr_repository_policy" "this" {
  for_each = length(var.pull_principal_arns) > 0 || length(var.push_principal_arns) > 0 ? var.repositories : {}

  repository = aws_ecr_repository.this[each.key].name
  policy     = data.aws_iam_policy_document.repository[0].json
}

###############################################################################
# Registry-wide enhanced scanning (Amazon Inspector)
###############################################################################

resource "aws_ecr_registry_scanning_configuration" "this" {
  count = var.enable_enhanced_scanning ? 1 : 0

  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"

    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}
