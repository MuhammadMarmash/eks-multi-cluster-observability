mock_provider "aws" {}

variables {
  name_prefix = "obs-platform-prod"
  account_id  = "123456789012"

  oidc_provider_arn  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"
  oidc_provider_host = "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"
  cluster_name       = "obs-platform-prod-observability"
}

run "one_bucket_per_signal_globally_unique" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket.this) == 3
    error_message = "One bucket per signal: metrics, logs, traces."
  }

  # S3 names are globally unique across every AWS account on earth. Without the
  # account suffix this collides with anyone else who picked the same project
  # slug, and the failure is at apply time on a name you cannot have.
  assert {
    condition     = aws_s3_bucket.this["loki"].bucket == "obs-platform-prod-loki-123456789012"
    error_message = "Bucket names must carry the account ID suffix."
  }
}

run "data_is_not_disposable" {
  command = plan

  assert {
    condition     = alltrue([for b in aws_s3_bucket.this : b.force_destroy == false])
    error_message = "force_destroy must be false. Observability data outlives the cluster; a destroy must fail on a non-empty bucket rather than silently emptying it."
  }
}

run "encrypted_at_rest_and_closed_to_the_public" {
  command = plan

  assert {
    condition = alltrue([
      for e in aws_s3_bucket_server_side_encryption_configuration.this :
      one(one(e.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    ])
    error_message = "SSE-S3 (AES256) on every bucket."
  }

  assert {
    condition = alltrue([
      for p in aws_s3_bucket_public_access_block.this :
      p.block_public_acls && p.block_public_policy && p.ignore_public_acls && p.restrict_public_buckets
    ])
    error_message = "All four public access blocks must be on. Telemetry contains request paths, user IDs and stack traces."
  }
}

run "lifecycle_matches_each_signals_access_pattern" {
  command = plan

  # Metrics and logs are queried in bulk time ranges, so Standard-IA's
  # per-GB retrieval fee is amortised across large scans.
  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.this["mimir"].rule : r if length(r.transition) > 0]) == 1
    error_message = "Mimir must transition to Standard-IA."
  }

  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.this["loki"].rule : r if length(r.transition) > 0]) == 1
    error_message = "Loki must transition to Standard-IA."
  }

  # Traces are needle-in-haystack lookups: you fetch one trace from last
  # Tuesday. Standard-IA's retrieval fee applies per GB fetched, so an IA
  # trace bucket costs MORE than Standard under real query load.
  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.this["tempo"].rule : r if length(r.transition) > 0]) == 0
    error_message = "Tempo must NOT transition to Standard-IA — random-access retrieval costs more than the storage saved."
  }
}

run "failed_compactor_uploads_are_reaped" {
  command = plan

  # An aborted multipart upload is billed forever and is invisible in the
  # console's object listing. Compactors produce them on every OOM.
  assert {
    condition = alltrue([
      for lc in aws_s3_bucket_lifecycle_configuration.this :
      length([
        for r in lc.rule : r
        if length(r.abort_incomplete_multipart_upload) > 0
        && one(r.abort_incomplete_multipart_upload).days_after_initiation == 7
      ]) == 1
    ])
    error_message = "Every bucket needs a 7-day abort_incomplete_multipart_upload rule."
  }
}

run "each_role_reaches_exactly_one_bucket" {
  command = plan

  assert {
    condition     = length(module.irsa) == 3
    error_message = "One IRSA role per component."
  }

  # The whole point of three roles instead of one. If Loki's policy names
  # Mimir's bucket, a Loki compromise reads every metric you have.
  assert {
    condition     = !strcontains(output.policy_documents["loki"], "obs-platform-prod-mimir-123456789012")
    error_message = "Loki's policy must not reference Mimir's bucket."
  }

  assert {
    condition     = !strcontains(output.policy_documents["loki"], "obs-platform-prod-tempo-123456789012")
    error_message = "Loki's policy must not reference Tempo's bucket."
  }

  assert {
    condition     = strcontains(output.policy_documents["loki"], "obs-platform-prod-loki-123456789012")
    error_message = "Loki's policy must reference its own bucket."
  }
}

run "policies_carry_no_wildcards" {
  command = plan

  assert {
    condition     = alltrue([for p in output.policy_documents : !strcontains(p, "\"s3:*\"")])
    error_message = "No wildcard actions. Every permitted call is named."
  }

  assert {
    condition     = alltrue([for p in output.policy_documents : !strcontains(p, "\"Resource\":\"*\"")])
    error_message = "No wildcard resources."
  }
}

run "multipart_permissions_are_present" {
  command = plan

  # These break COMPACTION, not ingestion — so the failure appears days after
  # a deploy that looked healthy, on large blocks only.
  assert {
    condition     = alltrue([for p in output.policy_documents : strcontains(p, "s3:AbortMultipartUpload")])
    error_message = "s3:AbortMultipartUpload is required to clean up failed large-block uploads."
  }

  assert {
    condition     = alltrue([for p in output.policy_documents : strcontains(p, "s3:ListMultipartUploadParts")])
    error_message = "s3:ListMultipartUploadParts is required to resume large-block uploads."
  }

  assert {
    condition     = alltrue([for p in output.policy_documents : strcontains(p, "s3:ListBucketMultipartUploads")])
    error_message = "s3:ListBucketMultipartUploads is the bucket-level half; without it the compactor cannot enumerate its own in-flight uploads."
  }
}

run "service_account_names_are_pinned_not_derived" {
  command = plan

  # Chart-generated names embed the Helm release name (m-mimir, t-tempo),
  # which stage 1 cannot know. Stage 2 must set serviceAccount.name to these.
  assert {
    condition     = output.service_account_names["mimir"] == "mimir-sa"
    error_message = "Mimir's ServiceAccount name must be pinned."
  }

  assert {
    condition     = output.service_account_names["loki"] == "loki-sa"
    error_message = "Loki's ServiceAccount name must be pinned."
  }

  assert {
    condition     = output.service_account_names["tempo"] == "tempo-sa"
    error_message = "Tempo's ServiceAccount name must be pinned."
  }
}
