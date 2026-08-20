# ADR 0003 — S3 backend with native state locking, no DynamoDB

**Status:** Accepted
**Date:** 2026-08-20
**Implemented by:** `terraform/bootstrap`, `terraform/envs/prod/backend.tf`

## Context

Terraform state is the map of every resource this platform owns. It must be remote (so CI
and engineers share one source of truth), versioned (so a corrupted push is recoverable),
encrypted (state stores resource attributes verbatim, including sensitive values), and
locked (so two concurrent applies cannot interleave).

The long-standing AWS pattern pairs an S3 bucket with a DynamoDB table for locking. That
pattern predates a capability S3 now has natively.

## Decision

An S3 backend with `use_lockfile = true`, and **no DynamoDB table anywhere in the
platform**.

Terraform 1.10+ supports native S3 state locking: the lock is a `<key>.tflock` object
written into the same bucket using S3's conditional-write (compare-and-swap) semantics.
The DynamoDB locking arguments are deprecated as of Terraform 1.11, which is why
`required_version` is pinned at `>= 1.11.0`.

This removes an entire resource, its IAM surface, its bootstrap step, and its (small but
real) cost from the platform, and eliminates a class of drift where the lock table exists
in one environment but not another.

## Bucket hardening

Created once by `terraform/bootstrap` with local state, which is the standard resolution
of the backend chicken-and-egg problem:

- **Versioning enabled** — the only recovery path from a truncated or corrupted state
  push, and what makes `terraform state` surgery survivable.
- **SSE-KMS** with a customer-managed, rotating key (SSE-S3 available via a variable).
- **Public access blocked**, `BucketOwnerEnforced` ownership.
- **Bucket policy denying** non-TLS requests and unencrypted uploads.
- **`prevent_destroy`** lifecycle guard — losing this bucket means losing the map of every
  resource the platform owns.
- Noncurrent versions expire after 90 days, keeping 20 versions, so the bucket does not
  grow without bound.

Backend values (bucket, region, KMS key) are passed at init time via a gitignored
`backend.hcl`, so `backend.tf` stays account-agnostic and safe to commit.

## Consequences

- **Terraform 1.11+ is mandatory.** An engineer on 1.9 cannot init this repo. This is
  enforced by `required_version` rather than left to documentation.
- The bootstrap module's own state is local and committed nowhere. Re-creating it is a
  `terraform import` away, and `prevent_destroy` plus versioning protect the bucket in the
  meantime.
- Lock contention surfaces as an S3 conditional-write failure rather than a DynamoDB
  error. Same outcome, different message in the logs.

## Alternatives considered

| Option | Why not |
|---|---|
| S3 + DynamoDB lock table | Deprecated in Terraform 1.11+. An extra resource, IAM policy, bootstrap step and cost for capability S3 now provides natively. |
| Terraform Cloud / HCP | Introduces an external dependency and account outside the assessed AWS environment. |
| Local state | Not shareable with CI, trivially lost, and would put secrets on a laptop. |
