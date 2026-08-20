# ADR 0002 — VPC peering for the cross-cluster telemetry pipeline

**Status:** Accepted
**Date:** 2026-08-20
**Implemented by:** `terraform/modules/security`

## Context

[ADR 0001](0001-two-vpc-architecture.md) puts the two clusters in separate VPCs. Telemetry
still has to get from Cluster A to Cluster B: metrics, logs and traces, continuously, at
volume, and without any of it resting permanently on Cluster A.

Three transports were on the table: public endpoints, VPC peering, and AWS PrivateLink.

## Decision

**VPC peering**, carrying OTLP on ports `4317` (gRPC) and `4318` (HTTP) and nothing else.

- **Public endpoints** would push every span, log line and sample across the internet,
  force a public ingress on the observability cluster, and turn the telemetry pipeline
  into an attack surface. Rejected outright.
- **PrivateLink** is the right answer at multi-account or multi-team scale: it is
  unidirectional, non-transitive, and needs no CIDR coordination. But it bills per
  endpoint-hour *plus* per GB, and telemetry is high-volume by definition. It also
  requires an NLB in front of every exposed service. Wrong cost and complexity profile
  for two VPCs in one account.
- **VPC peering** is free to create, carries no per-hour charge (only standard
  intra-Region data transfer), is fully private, and is trivial to reason about for a
  two-VPC, single-account, single-Region topology.

## Security model

The posture deliberately does not rest on "it is a private link". Three independent layers
enforce it:

1. **Routing.** Only the *private* subnets on each side have a route to the peer. Public
   subnets deliberately do not, so nothing that lands in a public subnet can reach the
   observability VPC at all.
2. **Security groups.** The observability side accepts `4317`/`4318` from the workload VPC
   CIDR and nothing else. The workload side may egress to the observability CIDR on those
   same two ports and nothing else. Each SG is attached to the corresponding cluster's
   nodes by the root module.
3. **Application.** TLS plus bearer-token auth terminates at the Gateway Collector inside
   Cluster B. The peering link carries encrypted traffic; it does not replace transport
   security.

CIDR-scoped rules are used rather than cross-VPC security-group references: they are
portable, auditable, and do not depend on the peer relationship staying in one Region.

## Consequences

- The two VPC CIDRs must never overlap. Peering rejects overlapping ranges outright, so
  this is enforced by AWS rather than by convention — but it does constrain future IP
  planning.
- Peering is **not transitive**. A third VPC added later cannot reach Cluster B through
  Cluster A; it needs its own link. At three or more spokes, revisit PrivateLink or a
  Transit Gateway.
- Adding a signal that does not speak OTLP (pushing directly to Loki on 3100, say)
  requires an explicit rule. The `extra_observability_ingress` variable exists for this
  and keeps such exceptions visible in code review.

## Alternatives considered

| Option | Cost | Isolation | Why not |
|---|---|---|---|
| Public endpoints + TLS | Data transfer out | Weakest — public ingress on Cluster B | Telemetry over the internet; unacceptable attack surface |
| **VPC peering** | Free + intra-Region transfer | Private, CIDR-coordinated, non-transitive | **Chosen** |
| PrivateLink | Per endpoint-hour + per GB | Strongest — unidirectional, no CIDR coordination | Cost profile is wrong for high-volume telemetry; needs an NLB per service. Revisit when observability moves to its own account. |
| Transit Gateway | Per attachment-hour + per GB | Strong, transitive, scales to many VPCs | Overkill for exactly two VPCs |
