# Proof of life

Evidence that all three signals leave Cluster A, cross the VPC peering link, and land in
storage backed by S3 and reached from Cluster B.

Every screenshot is Grafana running in **Cluster B**. Every query filters on
`obs-platform-prod-workload` — a label stamped by the Alloy agent on **Cluster A** and by
nothing else, so the data cannot have originated where it is being read.

## 1. Metrics — Mimir

![Mimir showing metrics from Cluster A](01-mimir-metrics-from-cluster-a.png)

```promql
sum by (cluster) (rate(container_cpu_usage_seconds_total{cluster="obs-platform-prod-workload"}[5m]))
```

Container CPU scraped from Cluster A's kubelets, grouped by originating cluster.

## 2. Traces — Tempo

![A distributed trace from Cluster A](02-tempo-distributed-trace.png)

```traceql
{ resource.cluster = "obs-platform-prod-workload" && resource.service.name = "frontend-proxy" }
```

One request across **three services and eight spans**:
`frontend-proxy ingress → frontend GET /api/cart → grpc oteldemo.CartService → cart → HGET`.
The Redis `HGET` at the leaf is the storefront's cart lookup — a full distributed trace, not
a single service talking to itself.

## 3. Service graph — Tempo + Mimir

![The service graph rendered from span metrics](03-tempo-service-graph.png)

RED metrics per operation (rate, error rate, p90 duration) and the node graph of the service
topology.

Worth knowing how this one works, because it looks like a Tempo feature and is not: the
graph reads `traces_service_graph_*` metrics from the **Prometheus datasource**, and those
are produced by Tempo's metrics generator and remote-written into Mimir. It exercises both
backends at once.

## 4. Logs — Loki

![Loki showing logs from Cluster A](04-loki-logs-from-cluster-a.png)

```logql
{k8s_namespace_name="boutique"} | cluster="obs-platform-prod-workload"
```

Roughly 33,000 lines over six hours from the application namespace on Cluster A. The
**Common labels** row reads `cluster=obs-platform-prod-workload  k8s_namespace_name=boutique`,
which is the attribution stated plainly by Grafana itself.

Note the selector: `cluster` arrives as **structured metadata**, not an index label, so it
filters with `|` and cannot be used as a stream selector. `{cluster="..."}` returns nothing.

## The same claims from the API

[`evidence.txt`](evidence.txt) records all of the above as raw API responses, plus the S3
object counts, so the screenshots are not the only artefact.

| Signal | Backend | Attribution |
|---|---|---|
| Metrics | Mimir | `cluster` label |
| Traces | Tempo | `resource.cluster` — 12 services reporting |
| Logs | Loki | `cluster` structured metadata — 13 services reporting |
| Span metrics | Tempo → Mimir | `traces_service_graph_request_total` present |

## Reproducing

```bash
kubectl config use-context <observability-cluster>
kubectl -n lgtm port-forward svc/grafana 3000:80
terraform -chdir=terraform/envs/prod-platform output -raw grafana_admin_password
```

Two things that will otherwise waste time:

- **Query Mimir through `mimir-gateway`, never the query-frontend.** The gateway injects the
  `X-Scope-OrgID` tenant header; without it Mimir answers `401: no org id` to everything.
- **Hard-refresh Grafana after any restart.** It serves content-hashed assets, so a tab held
  open across a pod restart fails to lazy-load datasource plugins with
  `TypeError: Cannot read properties of undefined (reading 'call')`. The backend is fine; the
  browser is holding chunks the new pod no longer serves.
