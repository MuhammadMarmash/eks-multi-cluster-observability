###############################################################################
# modules/lgtm-storage
#
# Durable object storage for the LGTM stack, and the IRSA roles that reach it.
# No component holds a long-lived access key; no component can read another
# component's bucket.
#
#   docs/adr/0010-cloud-native-storage-and-irsa.md
#
# Buckets and roles live in one module on purpose: each role's policy is derived
# from its bucket's ARN, and splitting them would mean plumbing ARNs between
# modules to express a coupling that is inherent.
#
# VERSIONING IS DELIBERATELY OFF. Mimir, Loki and Tempo treat objects as
# immutable and their compactors delete source blocks continuously. Versioning
# would turn every one of those deletes into a noncurrent version that still
# bills, with no recovery benefit — nothing ever overwrites an object in place.
# Durability comes from force_destroy = false and S3's own eleven nines.
###############################################################################

locals {
  tags = merge(
    var.tags,
    {
      "Module"    = "lgtm-storage"
      "ManagedBy" = "terraform"
    },
  )

  bucket_names = {
    for k, c in var.components :
    k => "${var.name_prefix}-${k}-${var.account_id}"
  }

  bucket_arns = {
    for k, c in var.components :
    k => "arn:aws:s3:::${local.bucket_names[k]}"
  }

  # Least privilege, split by the level the action applies at. Every action is
  # named; there is no s3:* anywhere and no resource wildcard beyond the
  # component's own key space.
  policy_documents = {
    for k, c in var.components :
    k => jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid    = "BucketLevelOperations"
          Effect = "Allow"
          Action = [
            "s3:ListBucket",
            "s3:GetBucketLocation",
            # Without this the compactor cannot enumerate its own in-flight
            # uploads, so it can neither resume nor clean them up.
            "s3:ListBucketMultipartUploads",
          ]
          Resource = local.bucket_arns[k]
        },
        {
          Sid    = "ObjectLevelOperations"
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            # The multipart pair. These break COMPACTION, not ingestion, so a
            # deploy missing them looks healthy for days and then stops
            # compacting large blocks.
            "s3:AbortMultipartUpload",
            "s3:ListMultipartUploadParts",
          ]
          Resource = "${local.bucket_arns[k]}/*"
        },
      ]
    })
  }
}

###############################################################################
# Buckets
###############################################################################

resource "aws_s3_bucket" "this" {
  for_each = var.components

  bucket = local.bucket_names[each.key]

  # Observability data outlives the cluster that produced it. A `terraform
  # destroy` must FAIL on a non-empty bucket rather than quietly deleting every
  # log line retained for compliance. Emptying is a deliberate administrative
  # act, not a side effect of tearing down infrastructure.
  force_destroy = false

  tags = merge(local.tags, {
    "Name"      = local.bucket_names[each.key]
    "Component" = each.key
    "Signal"    = each.value.signal
  })
}

# SSE-S3 rather than SSE-KMS. KMS bills per request, and these are the most
# request-heavy buckets in the platform — a compacting Loki issues thousands of
# PUTs an hour. The trade-off, and what it costs in control, is documented in
# ADR 0010.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = var.components

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    # A no-op under SSE-S3, set so that switching to SSE-KMS later is a
    # one-line change rather than a rethink: with a bucket key, KMS is charged
    # per bucket-key refresh instead of per object.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = var.components

  bucket = aws_s3_bucket.this[each.key].id

  # Telemetry is not anonymous data: logs carry request paths, user identifiers
  # and stack traces. All four, unconditionally.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs are a legacy access path that sits beside the bucket policy. Enforcing
# bucket-owner ownership disables them outright, so the IAM policies above are
# the only thing that grants access.
resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = var.components

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

###############################################################################
# Lifecycle
#
# Each signal gets the policy its ACCESS PATTERN justifies, not a uniform one.
#
#   Metrics and logs are read in bulk time ranges, so Standard-IA's per-GB
#   retrieval fee is amortised across a large scan. Transition at 30 days,
#   which is also Standard-IA's minimum billable duration.
#
#   Traces are read one at a time — you fetch the single slow request from last
#   Tuesday. That retrieval fee applies per GB fetched with no scan to amortise
#   it against, so an IA trace bucket costs MORE than Standard. Tempo stays in
#   Standard for its whole (short) life.
#
# Note that Standard-IA also bills a 128 KB minimum per object. Loki chunks and
# Tempo blocks are often smaller, so part of the nominal IA discount is eaten by
# rounding — another reason not to reach for it reflexively.
###############################################################################

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = var.components

  bucket = aws_s3_bucket.this[each.key].id

  # Always present, on every bucket. See the variable's description for why
  # this is not merely tidiness.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_upload_days
    }
  }

  # Rendered only for components whose access pattern justifies it.
  dynamic "rule" {
    for_each = each.value.transition_ia_days == null ? [] : [each.value.transition_ia_days]

    content {
      id     = "transition-to-standard-ia"
      status = "Enabled"

      filter {}

      transition {
        days          = rule.value
        storage_class = "STANDARD_IA"
      }
    }
  }

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = each.value.expiration_days
    }
  }

  depends_on = [aws_s3_bucket_ownership_controls.this]
}

###############################################################################
# IRSA
#
# One role per component, each assumable by exactly one ServiceAccount and
# granting access to exactly one bucket. Three roles rather than one shared
# role is the whole point: if Loki's pod is compromised, it cannot read a
# single metric or trace.
#
# The ServiceAccount names are PINNED here. The LGTM charts derive their default
# names from the Helm release name (`m-mimir`, `t-tempo`), which this layer
# cannot know — stage 2 must set `serviceAccount.name` to match these exactly.
# If it drifts, the pod gets no role, silently falls back to the node role, and
# fails on its first S3 write with an opaque AccessDenied.
###############################################################################

module "irsa" {
  source   = "../irsa"
  for_each = var.components

  role_name          = "role-${var.cluster_name}-${each.key}-s3"
  oidc_provider_arn  = var.oidc_provider_arn
  oidc_provider_host = var.oidc_provider_host
  namespace          = var.namespace
  service_account    = each.value.service_account
  description        = "${title(each.key)} ${each.value.signal} storage — ${local.bucket_names[each.key]}"

  inline_policy_json = local.policy_documents[each.key]

  tags = merge(local.tags, {
    "Component" = each.key
    "Signal"    = each.value.signal
  })
}
