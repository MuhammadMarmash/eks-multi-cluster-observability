# ADR 0009 — The workload application on Cluster A

**Status:** Superseded by the decision recorded below, 2026-08-23
**Date:** 2026-08-21
**Implemented by:** `terraform/modules/workload-app`

> ## Superseded: the pinned fork publishes no images
>
> The original decision below verified that
> `julianocosta89/opentelemetry-microservices-demo` is OTLP-instrumented. It did not
> verify that anything **publishes built images** for it, and nothing does. Its manifests
> carry placeholder image names (`image: frontend`) and it builds all eleven services from
> source through a 2021-era Skaffold config spanning Go, C#, Python, Node and Java. Its
> services also point at a bundled `otelcollector:4317` rather than at an injectable
> endpoint.
>
> Deploying it means running that build, which is hours of work across five toolchains with
> a real chance the 2021 config no longer builds on current ones.
>
> **The workload application is now `open-telemetry/opentelemetry-demo`**, deployed from the
> `opentelemetry-demo` Helm chart (0.41.0, appVersion 3.0.0):
>
> - It publishes prebuilt instrumented images to `ghcr.io/open-telemetry/demo`, all fifteen
>   services sharing one repository and differing only by tag — three mirrored ECR
>   repositories rather than seventeen.
> - Every service builds its OTLP endpoint from a single `OTEL_COLLECTOR_NAME` variable, so
>   pointing the whole application at the Alloy agent is one value.
> - It emits traces, metrics **and** logs over OTLP natively, where the Boutique emits
>   traces only.
> - It is actively maintained by the OpenTelemetry project.
>
> **What this costs:** it is the Astronomy Shop, not the Online Boutique the brief names by
> name. The brief's *intent* — an OTLP-instrumented microservices demo whose telemetry
> proves the pipeline — is met better; its *letter* is not. That trade is deliberate and is
> recorded here rather than left for a reader to discover.
>
> The chart's own Jaeger, Prometheus, Grafana and OpenSearch are disabled. That stack is the
> point of the upstream demo and entirely redundant here: this platform *is* the
> observability stack, in another cluster, which is the thing being demonstrated.
>
> **The lesson worth keeping:** "is it instrumented?" was the wrong question to stop at. The
> question that decides whether a dependency is usable is "can I obtain it without building
> it?", and it costs one look at the manifests to answer.

## Context

Cluster A exists to produce telemetry worth shipping. The brief calls for the Google
Online Boutique microservices demo and states that it is already instrumented with
OpenTelemetry, so no application code needs modifying.

That is true of *one* variant of it, and not of the upstream original. `GoogleCloudPlatform/microservices-demo`
ships with Google Cloud Operations instrumentation, not vendor-neutral OTLP export. Picking
the wrong repository means either rewriting application code — explicitly out of scope — or
discovering late that no traces reach the gateway.

## Decision

The workload application is deployed from **exactly this repository**:

> **https://github.com/julianocosta89/opentelemetry-microservices-demo**

This is the OpenTelemetry-instrumented fork of Online Boutique. Every service emits OTLP
natively and honours `OTEL_EXPORTER_OTLP_ENDPOINT`, which is the whole reason the pipeline
needs no application changes.

**This is binding.** Any future Helm chart, Kubernetes manifest, or ECR mirror entry for
Cluster A resolves to this repository and no other. A substitution here does not fail
loudly — it fails as an empty Grafana panel at the end of an otherwise green deploy.

## Wiring

The services are pointed at the local Alloy DaemonSet, not at anything in Cluster B. The
agent is the only thing on Cluster A that knows the gateway exists.

```
OTEL_EXPORTER_OTLP_ENDPOINT = http://alloy-agent.telemetry.svc.cluster.local:4317
```

That value is published as the `agent_otlp_endpoint` output of `envs/prod-platform`, so the
application deployment reads it rather than hardcoding it.

## Consequences

- Images must be mirrored into ECR before deployment, like everything else
  ([ADR 0005](0005-container-supply-chain.md)). The `boutique/*` repositories already
  declared in `envs/prod`'s `ecr_repositories` are for these, and the exact service list
  should be reconciled against the fork rather than assumed from the upstream original.
- The fork tracks upstream at its own pace. Pin a tag or commit when mirroring; a floating
  `latest` would make the Proof of Life unreproducible.
- Traces arriving at the gateway carry `service.name` values from this fork. Any dashboard
  built in Section 3 keys on those names.

## Alternatives considered

| Option | Emits OTLP | Code changes needed | Why not |
|---|---|---|---|
| `GoogleCloudPlatform/microservices-demo` | No — Cloud Operations | Yes, substantial | The brief rules application changes out of scope |
| `open-telemetry/opentelemetry-demo` | Yes | None | A different application (astronomy shop), not the Boutique the brief names |
| **`julianocosta89/opentelemetry-microservices-demo`** | Yes | None | **Chosen** — the Boutique, instrumented for OTLP |
