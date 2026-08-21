# ADR 0006 — Grafana Alloy as the unified telemetry agent

**Status:** Accepted
**Date:** 2026-08-21
**Implemented by:** `terraform/modules/telemetry-agent`, `terraform/modules/telemetry-gateway`

## Context

Cluster A has to produce three signals — metrics, logs and traces — and none of them may
rest permanently there. The brief names two acceptable collectors: the upstream
OpenTelemetry Collector and Grafana Alloy.

The constraint that decides it comes from [ADR 0002](0002-cross-vpc-telemetry-transport.md):
exactly two ports, `4317` and `4318`, cross the peering link. Whatever runs on Cluster A
has to get all three signals through that opening.

## Decision

**Grafana Alloy**, as a single DaemonSet on Cluster A and a Deployment acting as the
gateway on Cluster B.

The upstream Collector handles OTLP well and would cover traces and any application
metrics the Boutique emits. It does not, conventionally, cover Kubernetes infrastructure
metrics or pod logs — those want a Prometheus agent and Promtail alongside it. Three
agents, three configuration languages, three sets of RBAC, and three things to notice have
died on every node.

Alloy is an OTLP-compatible distribution of that same Collector, so nothing about the
OTLP path changes. What it adds is native `prometheus.scrape` and `loki.source.file`
components *plus* the `otelcol.receiver.prometheus` and `otelcol.receiver.loki` bridges
that convert those streams into OTLP in-process. All three signals therefore converge on
one exporter and leave on one authenticated connection, which is what keeps the peering
link at two ports rather than five.

Its configuration language is HCL-shaped, which is the same shape as the rest of this
repository. That is a small thing, but it is not nothing when the person debugging the
pipeline at 3am has been reading Terraform all day.

## Consequences

- This is a Grafana distribution, not pure upstream. Component names are Alloy's
  (`otelcol.receiver.otlp`, not `receivers: otlp:`), so an upstream Collector configuration
  does not port across unchanged, and neither does the reverse. The concepts transfer; the
  syntax does not.
- One DaemonSet means one config, one set of RBAC and one set of health metrics to alert
  on. It also means one blast radius: an Alloy config error stops all three signals, where
  three agents would have degraded one at a time.
- Alloy gates components by stability level and **refuses to start** when the configured
  level does not admit one it has been given. Every component in the agent pipeline is
  generally-available; the gateway raises the gate only while the pre-LGTM debug sink is in
  use. `scripts/validate-alloy-configs.sh` asserts both, because this failure surfaces as a
  `CrashLoopBackOff` on a running cluster rather than at plan time.
- Using Alloy on both ends means one tool to learn, and the gateway's fan-out to Mimir,
  Loki and Tempo is plain OTLP with no format conversion.

## Alternatives considered

| Option | Signals covered | Agents per node | Why not |
|---|---|---|---|
| OTel Collector alone | Traces, app metrics | 1 | No infrastructure metrics, no pod logs. Fails the brief outright |
| OTel Collector + Prometheus agent + Promtail | All three | 3 | Three configs and three failure modes per node; needs more than two ports open unless a collector fronts the other two anyway |
| **Grafana Alloy** | All three | 1 | **Chosen** — bridges Prometheus and Loki into OTLP in-process |
| Grafana Agent | All three | 1 | Superseded by Alloy; in maintenance |
