# ADR 0010 — Cloud-native storage for the LGTM stack, and the IRSA model that reaches it

**Status:** Accepted
**Date:** 2026-08-21
**Implemented by:** `terraform/modules/lgtm-storage`, called from `terraform/envs/prod`

## Context

Loki, Mimir and Tempo must not depend on node-attached disks for anything durable. The
cluster is torn down nightly against a $50 budget; if the data lives on an EBS volume
attached to a node, it dies with the node group, and the entire premise of a *centralized*
observability plane goes with it.

**"Durable" is the operative word.** This rules out node-attached disks as a *system of
record*; it does not rule out a scratch volume in front of one. Mimir's ingester keeps a
write-ahead log for the records it has acknowledged but not yet flushed into a block, and
that WAL is not optional — the ingester will not start without somewhere to put it. So one
PVC survives this decision, and only one: a small gp3 volume per ingester, described in
[Consequences](#consequences) below. Nothing that has reached S3 is on it, and losing it
costs at most the last flush interval.

Three questions follow from that: what encrypts the buckets, what ages the data out, and
how the components authenticate without a key sitting in a Secret somewhere.

## Decision

**Three buckets, three IAM roles, one role per signal.** SSE-S3 encryption, per-signal
lifecycle rules, IRSA only, and `force_destroy = false` everywhere.

```
<project>-<env>-mimir-<account>   metrics   IA @ 30d   expire @ 90d   lgtm/mimir-sa
<project>-<env>-loki-<account>    logs      IA @ 30d   expire @ 90d   lgtm/loki-sa
<project>-<env>-tempo-<account>   traces    never IA   expire @ 30d   lgtm/tempo-sa
```

The account ID suffix is not decoration. S3 bucket names are globally unique across every
AWS account on earth, so `obs-platform-prod-loki` will eventually collide with a stranger's
bucket, and the failure arrives at apply time on a name that cannot be acquired.

### Encryption: SSE-S3, and what it costs us

**SSE-S3 (AES256)**, not SSE-KMS.

KMS bills roughly **$0.03 per 10,000 requests**, and these are the most request-heavy
buckets in the platform — a compacting Loki issues thousands of PUTs an hour, each one a
separate KMS decrypt. Against a $50 total budget that is a real and recurring line item.

**The honest trade-off:** both options encrypt at rest with AES-256. The difference is *who
holds the key and who can audit its use*. With SSE-KMS you get a key policy as a second,
independent authorisation layer — a compromised IRSA role still cannot decrypt if the key
policy excludes it — plus a CloudTrail record of every decrypt. SSE-S3 gives neither. AWS
manages the key, and access is governed by the IAM policy alone.

For telemetry in a cost-capped lab that is the right call. For a production system holding
logs subject to a compliance regime, SSE-KMS with a customer-managed key is the right call,
and the defence-in-depth argument outweighs the request cost. `bucket_key_enabled = true`
is already set — a no-op under SSE-S3 — so that switch is a one-line change that also
collapses KMS charges to per-bucket-key rather than per-object.

### Lifecycle: per-signal, because access patterns differ

Uniform lifecycle rules across the three buckets would be simpler and would cost more.

**Metrics and logs → Standard-IA at 30 days, expire at 90.** Both are queried in bulk time
ranges — a dashboard scans hours or days of data at once — so Standard-IA's per-GB
retrieval fee is amortised across a large scan. Thirty days is also Standard-IA's minimum
billable duration, so transitioning earlier saves nothing; the module validates this.

**Traces → Standard for life, expire at 30 days.** This is the one that looks inconsistent
and is not. Trace retrieval is *needle in a haystack*: you fetch the single slow request
from last Tuesday, by ID. There is no large scan to amortise the retrieval fee against, so
a trace bucket on Standard-IA costs **more** than one on Standard under real query load.
Traces are also the most ephemeral signal — nobody debugs a latency spike from two months
ago — so a shorter retention does the cost work that a storage class transition cannot.

A second, less obvious tax: **Standard-IA bills a 128 KB minimum per object.** Loki chunks
and Tempo blocks are frequently smaller than that, so a 40 KB object is billed at 128 KB —
a 3× markup that eats part of the nominal IA discount. Worth knowing before reaching for IA
reflexively anywhere else.

**All three get a 7-day `abort_incomplete_multipart_upload` rule.** This is not
housekeeping. An abandoned multipart upload keeps billing for its uploaded parts
indefinitely *and does not appear in an object listing*, so the cost is both permanent and
invisible in the console. Compactors produce them on every OOM or eviction.

### Versioning: deliberately off

Mimir, Loki and Tempo treat objects as immutable — nothing is ever overwritten in place —
and their compactors delete source blocks continuously after merging them. Versioning would
turn every one of those deletes into a noncurrent version that still bills, with no
recovery benefit whatsoever. Durability comes from `force_destroy = false` and S3's own
eleven nines, not from keeping versions of objects nothing ever modifies.

### `force_destroy = false`

A `terraform destroy` **fails** on a non-empty bucket. That is the intent.

Observability data outlives the cluster that produced it: logs are retained for compliance,
metrics underwrite SLA and billing claims. Emptying these buckets must be a deliberate
administrative act, not a side effect of tearing down infrastructure for the night. This is
a departure from `ecr_force_delete = true` elsewhere in this repository, and the asymmetry
is the point — a container image can be rebuilt from a Dockerfile, and last month's logs
cannot be rebuilt from anything.

### IRSA: three roles, not one

Each role is assumable by exactly one `namespace/ServiceAccount` and grants access to
exactly one bucket ARN and its key space. No wildcard actions, no wildcard resources.

One shared role would be simpler and would mean a compromised Loki pod could read every
metric and every trace in the platform. Three roles make that lateral movement impossible
at the IAM layer rather than the application layer.

| Component | ServiceAccount | IAM role | Buckets reachable |
|---|---|---|---|
| Mimir | `lgtm/mimir-sa` | `role-<cluster>-mimir-s3` | `…-mimir` only |
| Loki | `lgtm/loki-sa` | `role-<cluster>-loki-s3` | `…-loki` only |
| Tempo | `lgtm/tempo-sa` | `role-<cluster>-tempo-s3` | `…-tempo` only |
| Grafana | *none* | *none* | *none* |

**Grafana deliberately gets no role and no bucket access.** It queries Mimir, Loki and
Tempo over HTTP and has no business holding an S3 credential. It is also the only component
in the stack exposed to human users, which makes it the one most worth keeping away from
the data at rest.

The permitted actions, split by the level they apply at:

| Level | Actions |
|---|---|
| Bucket | `s3:ListBucket`, `s3:GetBucketLocation`, `s3:ListBucketMultipartUploads` |
| Object | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts` |

**The three multipart permissions are the ones that get forgotten**, and their absence has
a nasty signature: they break *compaction*, not ingestion. A deploy without them looks
healthy for days — data arrives, dashboards populate — and then large blocks silently stop
compacting, storage grows without bound, and query latency degrades. Nothing in the initial
smoke test would catch it.

### The ServiceAccount names are pinned, and stage 2 must honour that

The LGTM charts derive their default ServiceAccount names from the **Helm release name** —
a release called `m` produces `m-mimir`, a release called `t` produces `t-tempo`. Stage 1
writes these trust policies long before stage 2 chooses a release name, so it cannot
possibly derive them.

The names above are therefore fixed, and **every LGTM Helm release must set
`serviceAccount.name` to match**. If it drifts, the pod is issued no role at all, silently
falls back to the node instance role, and fails on its first S3 write with an opaque
`AccessDenied` that points at nothing.

`terraform output lgtm_service_account_to_role` prints the mapping stage 2 needs.

## Consequences

- **`terraform destroy` will fail** while any bucket holds objects. That is by design;
  empty them explicitly first. The teardown section of the runbook says so.
- These buckets and roles live in `envs/prod`, not `envs/prod-platform`, so they **survive
  `make platform-destroy`**. Tearing down the Kubernetes layer nightly does not touch the
  data. That is the entire point of Section 3.
- Retention is capped at 90 days for metrics and logs, 30 for traces. Anything requiring
  longer retention needs a lifecycle change and a fresh look at cost.
- **One PVC remains, by necessity.** The Mimir ingester mounts a gp3 volume for its
  write-ahead log — the only node-attached storage anywhere in the stack. It is a staging
  buffer, not a system of record: every block it protects is replicated across ingesters and
  lands in S3 within the flush interval. Its `retentionPolicy` is `whenDeleted: Delete` /
  `whenScaled: Retain`, so a teardown reclaims it while a scale-down does not discard an
  un-flushed WAL. This is also why `modules/storage-class` exists — EKS ships **no default
  StorageClass**, and without one those PVCs sit `Pending` and the Helm release times out
  with `context deadline exceeded`, naming nothing useful.
- The `lgtm` namespace is now load-bearing. It is pinned in three trust policies, and
  moving the stack to a different namespace invalidates all three at once.
- Switching to SSE-KMS later requires a key, a key policy naming the three roles, and
  `kms:Decrypt`/`kms:GenerateDataKey` added to each policy. Existing objects are not
  re-encrypted; only new writes pick up the new default.

## Alternatives considered

| Option | Cost | Isolation | Why not |
|---|---|---|---|
| One bucket, prefixes per signal | Slightly lower | Weak — prefix-scoped IAM is easy to get subtly wrong | Lifecycle rules would have to be prefix-filtered, and one mistake exposes every signal |
| One shared IRSA role | Simpler | None between components | A Loki compromise reads all metrics and traces |
| Static IAM access keys in a Secret | Same | Worst — key never expires, lives in etcd | The brief forbids it, and rightly |
| SSE-KMS with a CMK | Higher, per request | Stronger — second authorisation layer, auditable | Right for production; wrong against a $50 budget with these request volumes |
| Uniform lifecycle across all three | Simpler | n/a | Traces on Standard-IA cost more than Standard under random-access retrieval |
| **Three buckets, three roles, per-signal lifecycle** | — | Strong | **Chosen** |
