# ADR 0001 — Two VPCs, one per cluster

**Status:** Accepted
**Date:** 2026-08-20
**Implemented by:** `terraform/modules/vpc`, instantiated twice in `terraform/envs/prod/main.tf`

## Context

The platform runs two EKS clusters:

- **Cluster A (workload)** — the instrumented application fleet plus the OpenTelemetry
  Collector agents that forward its telemetry.
- **Cluster B (observability)** — the centralized LGTM stack (Loki, Grafana, Tempo, Mimir).

Both could have been placed in a single VPC, separated only by namespaces, node groups
and security groups. That is cheaper — one set of NAT gateways instead of two, no peering
link to manage — and it is what most tutorials do.

We rejected it.

## Decision

Each cluster gets its own VPC: `vpc-workload` (`10.0.0.0/16`) and `vpc-observability`
(`10.1.0.0/16`). The only connectivity between them is the explicitly routed,
security-group-scoped peering link described in [ADR 0002](0002-cross-vpc-telemetry-transport.md).

Two reasons drive this, and both are structural rather than cosmetic.

### 1. Blast radius — the observability plane must outlive the application plane

Observability HQ is the tool you reach for *precisely when the workload plane is on fire*.
If both clusters shared a VPC they would share fate. One bad route-table change, one
exhausted NAT gateway, one security-group mistake, one CIDR collision during a migration,
one runaway workload saturating shared ENIs — any of these takes down the very system you
are using to diagnose the outage. You end up debugging blind, which is the one failure
mode an observability platform exists to prevent.

Separate VPCs give the observability plane an independent failure domain, an independent
control-plane endpoint, an independent egress path, and an independent security boundary.
Concretely: Cluster A can be destroyed and rebuilt from scratch — which, in a cost-capped
account, it repeatedly will be — while the LGTM stack and its S3-backed history keep
running untouched.

### 2. EKS VPC CNI IP exhaustion

The AWS VPC CNI assigns every Pod a *real, routable VPC IP address* from the subnet its
node sits in. Pods are not NATed behind the node, so Pod count is bounded by free subnet
addresses, not by node count.

The two clusters consume that address space on completely unrelated curves:

- The Boutique fleet scales with **user traffic**.
- Mimir, Loki and Tempo scale with **telemetry volume** — and each fans out into many
  horizontally-scaled components (ingesters, distributors, queriers, compactors,
  store-gateways).

Sharing one VPC means both draw from one finite pool. A scale-out of Mimir's ingesters
could starve the workload cluster of Pod IPs, leaving new Pods stuck in
`ContainerCreating` with `failed to assign an IP address to container`. Prefix delegation
makes this *worse*, not better, because each node reserves `/28` blocks up front.

Two `/16`s, each carrying `/20` private subnets (~4,090 usable IPs per AZ), keep the two
scaling curves fully independent and leave headroom for prefix delegation to be enabled.

## Consequences

**Accepted costs**

- One VPC peering connection to create and route (free to run; standard intra-Region data
  transfer charges apply).
- NAT gateways are per-VPC, so the HA configuration doubles from three to six.
- Cross-VPC traffic must be explicitly routed and explicitly allowed; nothing works by
  accident. This is the point, but it is friction.

**Gained**

- Independent failure domains, independently destroyable.
- No shared Pod IP pool.
- A natural migration path: moving observability into its own AWS account later becomes a
  provider-alias change plus swapping peering for PrivateLink, not a re-architecture.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Single VPC, separate node groups | Shared failure domain and shared Pod IP pool — both objections above apply in full. |
| Single VPC, separate subnets per cluster | Fixes IP contention only. Route tables, NAT and the default security group stay shared, so blast radius is unchanged. |
| Separate AWS accounts | The correct end state, and where this design points. Out of scope for a single shared lab account. |
