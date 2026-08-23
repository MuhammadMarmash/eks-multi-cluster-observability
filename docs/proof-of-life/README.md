# Proof of life

Evidence that telemetry leaves Cluster A, crosses the VPC peering link, and lands in
durable storage reached from Cluster B.

## What is proven

![Mimir in Cluster B showing metrics from Cluster A](01-mimir-metrics-from-cluster-a.png)

Grafana running in **Cluster B**, querying **Mimir**, rendering:

```promql
sum by (cluster) (rate(container_cpu_usage_seconds_total{cluster="obs-platform-prod-workload"}[5m]))
```

The series legend reads `obs-platform-prod-workload`. That label is stamped by the Alloy
agent on Cluster A and by nothing else, so the data cannot have originated locally — it
crossed the peering link, authenticated at the gateway, and was written to S3.

[`evidence.txt`](evidence.txt) captures the same claim from the API, plus the S3 object
counts and the NLB target health at the moment of capture.

| Signal | Status | Evidence |
|---|---|---|
| **Infrastructure metrics** | Flowing | Screenshot above; 38 objects in the Mimir bucket |
| **Pod logs** | Flowing | 8 objects in the Loki bucket; `service_name` label present |
| **Traces** | **None** | See below |

## What is NOT proven, and why

**There are no traces, because no application is deployed on Cluster A.**

Tempo is running and healthy, its bucket exists, and the gateway routes OTLP traces to it —
but nothing is emitting spans. The Alloy agent collects three signals: kubelet and cAdvisor
metrics, pod logs, and OTLP from applications. Only the first two have a source today.

Closing this needs the workload application from
[ADR 0009](../adr/0009-workload-application-source.md) — the OpenTelemetry-instrumented
Online Boutique — deployed to Cluster A with

```
OTEL_EXPORTER_OTLP_ENDPOINT = http://alloy-agent.telemetry.svc.cluster.local:4317
```

which is published as the `agent_otlp_endpoint` output of `envs/prod-platform`. Its images
must be mirrored into ECR first, per [ADR 0005](../adr/0005-container-supply-chain.md).

Until then this directory demonstrates the **pipeline**, not the full **fleet**: the
transport, the authentication, the storage and the query path are all real, and the thing
missing is a producer of application telemetry.

## Reproducing

```bash
kubectl config use-context <observability-cluster>
kubectl -n lgtm port-forward svc/grafana 3000:80
terraform -chdir=terraform/envs/prod-platform output -raw grafana_admin_password
```

Then Explore → Mimir → the query above. Note that Mimir must be queried through
`mimir-gateway`, not the query-frontend: the gateway injects the `X-Scope-OrgID` tenant
header, without which Mimir answers `401: no org id`.
