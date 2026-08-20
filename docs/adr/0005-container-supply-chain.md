# ADR 0005 — Private registry and image supply chain

**Status:** Accepted
**Date:** 2026-08-20
**Implemented by:** `terraform/modules/ecr`

## Context

The platform runs third-party images (Online Boutique, the LGTM components, the
OpenTelemetry Collector) and will run internally built ones. Pulling any of them straight
from Docker Hub or a public chart repo at deploy time means: no CVE policy, no audit trail
of what was actually deployed, exposure to upstream tag mutation, and exposure to registry
rate limits at the worst possible moment.

## Decision

Amazon ECR is the single source of container images **and** OCI Helm charts. Upstream
artifacts are mirrored in, scanned, and only then referenced by a cluster. Nothing is
pulled from a public source at deploy time.

Two controls are enforced module-wide and are deliberately **not** overridable per
repository:

### `image_tag_mutability = "IMMUTABLE"`

A tag can never be repointed at a different digest once pushed. This makes `app:1.4.2`
reproducible forever, prevents a compromised CI job from silently swapping the contents of
a released tag, and keeps GitOps rollbacks honest — rolling back to a tag gets you the
bits that tag has always meant.

### `scan_on_push = true`

Every push is CVE-scanned. Nothing enters a cluster unscanned.

Amazon Inspector **enhanced** scanning — continuous rescanning of already-pushed images as
new CVEs are published, with OS and language-package coverage — is available behind a
variable. It is off by default because it is billed per scan and is a registry-wide
(account + Region) setting, so exactly one Terraform root module may own it.

### Supporting controls

- **Encryption** with KMS (the AWS-managed `aws/ecr` key by default, adding CloudTrail
  visibility over key usage at no extra key cost).
- **Lifecycle policies** — untagged layers, which are garbage from failed or superseded
  builds, expire after 7 days; tagged releases are capped at the last 30 so storage stays
  bounded without deleting anything that might still be running.
- **Repository policies** are rendered only when explicit push/pull principals are
  supplied. Same-account pulls already work through `AmazonEC2ContainerRegistryReadOnly`
  on the node roles, so wiring a repository policy for the clusters themselves would add
  a needless module dependency. When a policy is rendered it also carries a blanket deny
  on non-TLS requests.

## Consequences

- **Immutable tags change CI.** A pipeline cannot re-push `:latest` or overwrite a release
  tag; every build must produce a new, unique tag. This is the intended discipline, and it
  will break any workflow that relies on moving tags.
- Mirroring is an explicit pipeline step. Upstream upgrades become a deliberate action
  with a scan gate, not an implicit pull.
- `force_delete` is defaulted to `true` in the prod tfvars so a cost-capped account can be
  torn down nightly. **Set it to `false` for anything real** — it currently allows a
  `terraform` teardown to remove repositories that still contain images.

## Alternatives considered

| Option | Why not |
|---|---|
| Pull from Docker Hub / public registries | No CVE gate, no audit trail, exposed to tag mutation and rate limits. Explicitly ruled out by the project brief. |
| `MUTABLE` tags | Convenient for `:latest` workflows, and precisely the property that makes a deployment irreproducible and a rollback untrustworthy. |
| Third-party registry (GHCR, Harbor) | Another identity system and another egress path. ECR keeps the trust boundary inside the AWS account and uses the same IAM the clusters already use. |
