# Day-2 operations

Upgrading the platform, and scaling the part of it that fills up first.

For deploying and verifying the telemetry pipeline, see
[`../RUNBOOK-telemetry.md`](../RUNBOOK-telemetry.md). This document assumes the platform is
already running.

---

## Read this first

Five properties of the current deployment shape every procedure below. Four of them are
deliberate trade-offs; the fifth is a gap.

| Property | Where it comes from | What it means here |
|---|---|---|
| **`replication_factor = 1`** on all three backends | `lgtm_replication_factor`, ADR 0010 sizing | No ingester holds a copy of another's data. Restarting an ingester without flushing **loses every sample since its last block flush.** This is the single fact that drives the whole upgrade procedure |
| **`kubernetes_version` is shared** by both clusters | `envs/prod/main.tf` lines 96 and 137 | Bumping the variable upgrades **both** control planes in one apply. Staging one cluster at a time needs `-target`, or a code change |
| **No metrics-server** | `modules/eks/addons.tf` installs vpc-cni, kube-proxy, coredns, ebs-csi only | `kubectl top` does not work and a CPU/memory HPA **cannot function at all**. This is a prerequisite for Part 2, not a detail |
| **Alloy retries for 5 minutes** | `max_elapsed_time = "5m"` in the agent's exporter | Cluster B can be unreachable for up to 5 minutes with no data loss. Past that, Cluster A drops telemetry on the floor |
| **The gateway Alloy has no PDB and no anti-affinity** | `modules/telemetry-gateway` — neither is configured | Both replicas can be scheduled on one node, and a drain can evict both at once. **Ingest goes to zero during a node roll.** See [Gaps](#gaps-to-close) |

---

# Part 1 — Upgrading EKS without losing telemetry

## The order, and why

AWS fixes most of it: **control plane → add-ons → nodes**, one minor version at a time, no
skipping. Add-ons must be able to talk to the new API server before any node is replaced,
because a node that comes up with an incompatible CNI never becomes Ready.

What is ours to decide is **which cluster goes first**, and the answer is **Cluster A
(workload)**.

The instinct is to upgrade the observability plane first — it is the more precious one. But
upgrading Cluster A while Cluster B is fully healthy means you can *watch* the upgrade
happen: pod restarts, error rates and latency are all visible in Grafana as it runs. Do it
the other way and you are upgrading the user-facing cluster blind.

Cluster B goes second. Its upgrade costs a telemetry gap and nothing user-facing, and the
gap is bounded by the agent's 5-minute retry buffer — provided the gateway stays up, which
is exactly what the missing PDB puts at risk.

## Step 0 — Pre-flight

```bash
# What is deployed now, per cluster.
terraform -chdir=terraform/envs/prod output -json cluster_addon_versions | jq .

# Anything the target version removes. Run for BOTH clusters.
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
```

Check the [EKS version support calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
and the target version's release notes for removed APIs. The charts in this repo are pinned,
so a removed API surfaces as a Helm release that fails to upgrade later, not as a broken
cluster — but it is cheaper to find now.

**Confirm the S3 buckets are healthy before touching anything.** They are the reason an
upgrade is recoverable at all:

```bash
terraform -chdir=terraform/envs/prod output -json lgtm_bucket_names \
  | jq -r '.[]' | xargs -I{} aws s3 ls s3://{} --summarize --human-readable | tail -3
```

## Step 1 — Control plane

One minor at a time. `1.34 → 1.35`, never `1.34 → 1.36`.

```hcl
# terraform/envs/prod/terraform.tfvars
kubernetes_version = "1.35"
```

Because the variable is shared, apply it to one cluster at a time:

```bash
cd terraform/envs/prod
terraform plan  -target=module.eks_workload -out=tfplan
terraform apply tfplan                                    # ~10 minutes
```

> `-target` is a break-glass tool and using it routinely hides drift. It is justified here
> because the alternative is upgrading both control planes simultaneously, which removes the
> ability to stop after the first one. Immediately afterwards, run a full `terraform plan`
> and confirm the only pending change is the second cluster.

The control plane stays available throughout — EKS upgrades it in place behind the same
endpoint. Existing workloads are untouched; only the API server version changes.

## Step 2 — Add-ons

**Do not skip this, and do not do it after the nodes.** kube-proxy must never be newer than
the API server, and the VPC CNI must support the new control plane before a new node tries
to register.

This repo makes it a no-op in the common case. `modules/eks/addons.tf` resolves each add-on
through `data.aws_eks_addon_version`, so any add-on **left unpinned in `addon_versions`
automatically moves to the default version for the new Kubernetes version**. If you have
pinned versions in `terraform.tfvars` — which production should — update them together:

```hcl
addon_versions = {
  "vpc-cni"            = "v1.21.x-eksbuild.1"
  "coredns"            = "v1.13.x-eksbuild.1"
  "kube-proxy"         = "v1.35.x-eksbuild.1"
  "aws-ebs-csi-driver" = "v1.52.x-eksbuild.1"
}
```

Find the compatible set with:

```bash
aws eks describe-addon-versions --kubernetes-version 1.35 \
  --addon-name vpc-cni --query 'addons[].addonVersions[].addonVersion' --output table
```

`resolve_conflicts_on_update = "PRESERVE"` is already set, which is what keeps the prefix
delegation settings in `vpc_cni_configuration` from being reset to defaults. That matters
more than it sounds: losing `ENABLE_PREFIX_DELEGATION` drops max-pods from 110 to 17 per
t3.medium and most of the platform becomes unschedulable.

Verify before moving on:

```bash
kubectl -n kube-system rollout status ds/aws-node ds/kube-proxy
kubectl -n kube-system rollout status deploy/coredns
kubectl get nodes -o wide     # every node still Ready
```

## Step 3 — Nodes

Managed node groups do the rolling replacement for us. The module already sets the knob:

```hcl
update_config {
  max_unavailable_percentage = var.node_max_unavailable_percentage   # default 33
}
```

At 33% of a 3-node group, EKS replaces **one node at a time**: it cordons, drains honouring
PodDisruptionBudgets, waits, then terminates. Trigger it by bumping the version and
applying — the node group inherits `kubernetes_version`.

For Cluster A that is the whole story. The Boutique is stateless, the charts carry PDBs, and
the Alloy DaemonSet simply restarts on the replacement node.

**For Cluster B it is not**, and the next section is why.

## Step 3b — Draining an ingester without losing data

This is the part a generic runbook gets wrong.

At `replication_factor = 1`, no second ingester holds a copy. The `mimir-ingester` PDB
allows `maxUnavailable: 1`, so **Kubernetes will happily evict an ingester that is the only
copy of the last two hours of metrics.** The PDB protects availability, not durability.

Mimir and Loki both expose a flush-and-leave endpoint. Use it before the drain reaches the
ingester, one at a time:

```bash
# Mimir: flush in-memory blocks to S3 and unregister from the ring.
kubectl -n lgtm exec mimir-ingester-0 -- \
  wget -qO- --post-data='' http://localhost:8080/ingester/shutdown

# Wait for the block to land in S3 before continuing.
kubectl -n lgtm logs mimir-ingester-0 --tail=20 | grep -i "finished flushing"

# Loki, same idea.
kubectl -n lgtm exec loki-write-0 -- \
  wget -qO- --post-data='' http://localhost:3100/ingester/shutdown
```

Then let the node roll. Repeat for the second ingester **only after the first has rejoined
the ring and reported Active**:

```bash
kubectl -n lgtm port-forward svc/mimir-distributor 8080:8080 &
curl -s localhost:8080/ingester/ring | grep -c ACTIVE   # expect 2 before continuing
```

The single-binary Tempo needs no equivalent: its WAL is short and its blocks flush on a
timer measured in minutes, so a restart costs minutes of traces rather than hours of
metrics.

**The cheaper alternative**, and the one to prefer if you have the headroom: raise
`lgtm_replication_factor` to 2 and `lgtm_ingester_replicas` to 3 for the duration of the
upgrade. With a real replica, an eviction costs nothing and the whole flush dance
disappears. It costs roughly 0.4 vCPU and 1 GiB while it runs — measured against the 40%
CPU / 75% memory the stack currently uses on three t3.medium nodes, that fits.

## Step 4 — The second cluster

Repeat Steps 1–3 with `-target=module.eks_observability`, then run an untargeted
`terraform plan` and confirm it is empty. An empty plan is the signal that the `-target`
detour left nothing behind.

## Verifying no gap

The pipeline reports on itself. From Cluster A:

```bash
kubectl -n telemetry exec ds/alloy-agent -- \
  wget -qO- localhost:12345/metrics | grep otelcol_exporter_send_failed
```

`otelcol_exporter_send_failed_spans` climbing means the gateway was unreachable for longer
than the 5-minute retry window and telemetry was dropped. Flat through the whole upgrade is
the proof the rubric asks for.

In Grafana, the honest check is a query that would show a hole:

```promql
count_over_time(up[1h])
```

against the upgrade window. A dip is a gap; a flat line is not.

## Rollback

**An EKS control plane cannot be downgraded.** There is no rollback step, and any runbook
that offers one is wrong.

What exists instead is rebuild, and it is cheap here specifically because of ADR 0010: every
byte that matters is in S3, outside the cluster, protected by `force_destroy = false`. A
Cluster B that cannot be recovered is destroyed and re-applied, and the new one reads the
same buckets. The data was never in the cluster.

That is the actual payoff of the storage design, and it is worth stating in a review: the
upgrade strategy is *safe because the storage strategy made the cluster disposable.*

---

# Part 2 — Autoscaling the Mimir ingesters

## Why the obvious answer is wrong

The obvious answer is `kubectl autoscale statefulset mimir-ingester --cpu-percent=70`. It
would be actively harmful, for three reasons.

**Ingesters are stateful in the way that matters.** Each holds the last two hours of series
in memory. Scaling *down* terminates a pod holding data no other pod has — the same
durability problem as Step 3b, now triggered automatically at 3am by a traffic dip.

**A new ingester does not relieve the existing ones.** It joins the hash ring and starts
receiving *newly hashed* series. The series already assigned to a hot ingester stay there
until they age out. So HPA cannot rescue an ingester that is already saturating — it can
only help with load that has not arrived yet. **Autoscaling here must lead the spike, not
react to it**, which inverts the usual reflex to trigger late and conservatively.

**Grafana does not ship it.** `mimir-distributed` 6.2.0 exposes `kedaAutoscaling` for the
*distributor* — stateless, safe to scale — and `ingester.kedaAutoscaling` is **null**. The
absence is a design opinion, not an oversight.

## Prerequisites we do not have

| Needed | Status | For |
|---|---|---|
| **metrics-server** | Not installed | Any CPU/memory HPA. Without it `kubectl top` fails and HPA reports `<unknown>` forever |
| **KEDA** or **prometheus-adapter** | Not installed | Custom metrics. KEDA is the better fit — it speaks PromQL directly and gives per-direction scaling policies |
| **Mimir scraping itself** | Not configured | Every metric below comes from Mimir's own `/metrics`. Today only Cluster A's kubelets are scraped |

That third row is the interesting one: **autoscaling the observability stack requires the
observability stack to observe itself.** Cluster B currently has no Alloy scraping its own
pods. That is the first thing to build, and it is a small addition to
`modules/telemetry-gateway` — a `prometheus.scrape` of the `lgtm` namespace feeding the
gateway's existing pipeline.

## The metrics that actually matter

CPU is the wrong primary signal. An ingester's binding constraint is **memory, driven by
active series count**, and it will OOM long before it saturates a core.

| Metric | What it tells you | Use |
|---|---|---|
| `cortex_ingester_memory_series` | Active series held per ingester | **Primary.** The real capacity signal. Grafana's own reference targets roughly 1.5M series per ingester; scale at ~70% of whatever your pods can actually hold |
| `container_memory_working_set_bytes` | Actual memory pressure | **Safety net.** Catches high-cardinality churn that series count alone misses |
| `cortex_ingester_ingested_samples_total` (rate) | Write throughput | **Leading indicator.** Rises before series count does, which is what buys the head start the ring behaviour demands |
| `cortex_inflight_requests` | Concurrent in-flight requests | **Saturation alarm, not a scaling trigger.** If this is climbing, the ingester is already failing to keep up and scaling now is too late. Page on it; do not autoscale on it |
| `cortex_ingester_ring_members{state="ACTIVE"}` | Healthy ring size | **Guard.** Never scale while this is below the desired replica count |

The rubric asks specifically about `inflight_requests`. It is worth being precise about why
it belongs in the alert path rather than the scaling path: by the time requests queue, the
ingester is saturated, and a new ingester will not take a single one of the series that
saturated it. It tells you that you scaled too late.

## Scale up fast, scale down almost never

```yaml
# KEDA ScaledObject — not applied; see Gaps.
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: mimir-ingester
  namespace: lgtm
spec:
  scaleTargetRef:
    kind: StatefulSet
    name: mimir-ingester
  minReplicaCount: 2          # never below replication_factor
  maxReplicaCount: 6          # bounded by node capacity, not by ambition
  pollingInterval: 30

  triggers:
    # Primary: active series, the real capacity limit.
    - type: prometheus
      metadata:
        serverAddress: http://mimir-gateway.lgtm.svc.cluster.local/prometheus
        query: sum(cortex_ingester_memory_series)
        threshold: "1000000"   # ~70% of what these pods hold at 384Mi

    # Leading indicator: throughput rises before series count does.
    - type: prometheus
      metadata:
        serverAddress: http://mimir-gateway.lgtm.svc.cluster.local/prometheus
        query: sum(rate(cortex_ingester_ingested_samples_total[5m]))
        threshold: "50000"

  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0      # react immediately
          policies:
            - type: Pods
              value: 2
              periodSeconds: 60

        scaleDown:
          # One hour. A shorter window scales down during a lull and takes
          # un-flushed series with it. Grafana's own reference uses 10% per
          # 600s for the stateless distributor; ingesters warrant far more.
          stabilizationWindowSeconds: 3600
          policies:
            - type: Pods
              value: 1
              periodSeconds: 1800            # at most one pod per 30 minutes
```

The asymmetry is the whole design. Scaling up costs money; scaling down costs data.

**Scale-down is still not safe on its own.** Removing a replica terminates an ingester
holding series no one else has. Two things make it survivable, and both are required:

- `-ingester.ring.unregister-on-shutdown=false`, so a terminating ingester leaves its
  tokens in the ring and a replacement inherits them rather than reshuffling every series.
- Mimir's **rollout-operator**, already deployed by the chart, which sequences StatefulSet
  changes so two ingesters never leave at once.

Without both, prefer `maxReplicaCount == minReplicaCount` and treat this as scale-up-only.
An observability stack that quietly drops metrics during a lull is worse than one that costs
a few dollars more overnight.

## Scaling the rest

The stateless components are the easy half and worth turning on first, because they carry no
durability risk at all:

| Component | Safe to autoscale | Signal |
|---|---|---|
| **distributor** | Yes — stateless. Chart supports it via `distributor.kedaAutoscaling` | CPU, `cortex_distributor_received_samples_total` rate |
| **querier** | Yes — stateless | `cortex_query_scheduler_queue_length` |
| **query-frontend** | Rarely needed | CPU |
| **ingester** | Only with the guards above | Active series |
| **store-gateway** | No — owns block shards | Scale manually |
| **compactor** | No — single-writer per tenant | Scale manually |

Turning on distributor autoscaling is a one-line change to `modules/lgtm-backends` once KEDA
exists, and it addresses the actual failure mode from a Boutique traffic spike: the write
path fills before the storage path does.

---

## Gaps to close

Found while writing this. All are real, none are blocking today, and each is small.

1. **No PDB or anti-affinity on the gateway Alloy.** Both replicas can land on one node and a
   single drain can evict both, taking ingest to zero. It is the one component whose outage
   the 5-minute retry buffer is protecting against, and it is the least protected thing in
   the platform. A `PodDisruptionBudget` with `maxUnavailable: 1` plus a
   `topologySpreadConstraint` on `kubernetes.io/hostname` closes it.
2. **`kubernetes_version` is shared by both clusters.** Staged upgrades need `-target` today.
   Splitting it into `workload_kubernetes_version` and `observability_kubernetes_version`
   removes the break-glass step from a routine procedure.
3. **No metrics-server.** Blocks `kubectl top` and every HPA. It is a managed EKS add-on and
   a three-line addition to `modules/eks/addons.tf`.
4. **Cluster B does not observe itself.** Every autoscaling metric above comes from Mimir's
   own `/metrics`, which nothing currently scrapes.
5. **`replication_factor = 1`** makes Step 3b necessary at all. Raising it to 2 during
   upgrades — or permanently, if the budget allows a fourth node — deletes the most
   error-prone procedure in this document.

Items 1 and 3 are the two worth doing before the next upgrade.
