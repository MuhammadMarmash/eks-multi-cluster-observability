###############################################################################
# bootstrap — remote state backend
#
# Chicken-and-egg resolver: this root module creates the S3 bucket that every
# OTHER root module uses as its backend. It is applied exactly once, with LOCAL
# state, and that state file is committed nowhere — re-creating it is a
# `terraform import` away and the bucket is protected from deletion.
#
# NOTE ON LOCKING: there is deliberately no DynamoDB table here. Terraform
# 1.10+ supports native S3 state locking via `use_lockfile = true`, which takes
# a conditional-write lock on a `<key>.tflock` object in the same bucket. That
# removes an entire resource, its IAM surface, and its (small but real) cost
# from the platform. DynamoDB-based locking is deprecated.
###############################################################################

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    # Reads GitHub's OIDC certificate so the provider thumbprint is discovered
    # rather than pinned to a literal that rotates.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Component = "terraform-state"
      ManagedBy = "terraform"
    }
  }
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  # Losing this bucket means losing the map of every resource the platform owns.
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = var.state_bucket_name }
}

# Versioning is REQUIRED, not optional: it is the only recovery path from a
# corrupted or truncated state push, and it is what makes `terraform state`
# surgery survivable.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_kms_key" "state" {
  count = var.use_customer_managed_key ? 1 : 0

  description             = "SSE-KMS key for the ${var.project} Terraform state bucket"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = { Name = "kms-${var.project}-tfstate" }
}

resource "aws_kms_alias" "state" {
  count = var.use_customer_managed_key ? 1 : 0

  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.state[0].key_id
}

# State files contain resource attributes verbatim, which frequently includes
# sensitive values. Encryption at rest is mandatory.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.use_customer_managed_key ? "aws:kms" : "AES256"
      kms_master_key_id = var.use_customer_managed_key ? aws_kms_key.state[0].arn : null
    }

    bucket_key_enabled = var.use_customer_managed_key
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Expire old state versions so the bucket does not grow without bound, while
# keeping a long enough window to recover from a bad apply.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 20
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Belt and braces: refuse any unencrypted or non-TLS access to state.
data "aws_iam_policy_document" "state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyUnEncryptedObjectUploads"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = var.use_customer_managed_key ? ["aws:kms"] : ["AES256", "aws:kms"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}
