# ADR 0007 — Cross-cluster name resolution for the telemetry gateway

**Status:** Accepted
**Date:** 2026-08-21
**Implemented by:** `terraform/modules/dns-private-zone`, `terraform/modules/telemetry-gateway`, `terraform/modules/aws-lb-controller`

## Context

[ADR 0002](0002-cross-vpc-telemetry-transport.md) settled the *transport*: VPC peering,
two ports, TLS and auth terminating at a gateway inside Cluster B. It did not settle how
Cluster A **finds** that gateway.

The two clusters share no DNS namespace. A name like
`alloy-gateway.telemetry.svc.cluster.local` is meaningful only inside the cluster that owns
it; from Cluster A it is nothing. Something has to give the gateway a name that resolves,
from Cluster A, to a private address in Cluster B.

## Decision

An **internal NLB** in Cluster B's private subnets, a **Route 53 private hosted zone
associated with both VPCs**, and a **CNAME** from `gateway.observability.internal` to the
load balancer.

### The resolution chain, step by step

This is the thing to have in front of you when the pipeline will not come up.

1. An Alloy pod on Cluster A resolves `gateway.observability.internal`. The name matches
   no `cluster.local` suffix and no stub domain, so CoreDNS forwards it to the upstream
   resolvers in the node's `/etc/resolv.conf` — the Amazon-provided resolver at the
   workload VPC's base address `+2`.
2. That resolver answers authoritatively, because the private hosted zone is **associated
   with `vpc-workload`** as well as `vpc-observability`. This association is the entire
   trick. Without it the query leaks past the resolver and returns NXDOMAIN.
3. The record is a CNAME to the NLB's AWS-generated name,
   `k8s-<hash>.elb.<region>.amazonaws.com`.
4. The resolver follows it. An internal NLB only ever has private addresses, and with
   `allow_remote_vpc_dns_resolution` enabled on both sides of the peering connection — it
   is, in `modules/security` — a querier in `vpc-workload` gets the NLB's private IPs in
   `vpc-observability`'s private subnets.
5. The pod connects. The private route tables in `vpc-workload` carry a route for the
   observability CIDR via the peering connection, so the packet never touches a NAT
   gateway or the internet.
6. The NLB's security group — `otlp-ingress-sg`, which `modules/security` already builds —
   admits `4317`/`4318` from the workload VPC CIDR and drops everything else.

### Why no CoreDNS change

A stub domain or a `forward` plugin edit would also work, and is what most write-ups
reach for. It is a ConfigMap, and the EKS CoreDNS add-on rewrites it on upgrade. Putting
resolution *below* Kubernetes means the Day-2 upgrade runbook has one less way to silently
break the pipeline.

### Why a CNAME and not an alias record

An alias record needs the target's hosted zone ID. The NLB is created by the AWS Load
Balancer Controller in response to a Service, so at the moment Terraform writes the record
that ID is not a value it holds. AWS keeps its own generated name resolving to current
private addresses regardless, so the CNAME loses nothing but a few milliseconds.

### Why the security group is on the load balancer

`otlp-ingress-sg` is attached to Cluster B's nodes by the root module, and that is where
the obvious reading stops. But the cross-VPC traffic arrives at the **NLB's** ENIs, and the
NLB uses `ip` target type — for which **client IP preservation is off by default**. Traffic
reaching the pod therefore appears to come from the load balancer, not from Cluster A, so a
CIDR rule attached only to the nodes matches nothing and quietly admits everything the
node's other groups allow.

The Service therefore carries
`service.beta.kubernetes.io/aws-load-balancer-security-groups` pointing at that same group,
with `manage-backend-security-group-rules: "true"` so the controller opens the node-side
rules itself. The node attachment stays as defence in depth.

## Consequences

- The internal NLB carries an hourly charge. It is the one running cost this layer adds on
  top of the two clusters — raw peering has none — so tear the platform layer down between
  test runs. `make platform-destroy`.
- `allow_remote_vpc_dns_resolution` must stay enabled on both sides of the peering
  connection. It is set in `modules/security`; removing it breaks step 4 in a way that
  looks like a routing fault.
- The zone name must keep a reserved suffix. `.internal` cannot exist in public DNS, so a
  query from an unassociated VPC fails closed. A name like `observability.example.com`
  would resolve *publicly* from anywhere the zone is not associated — the failure mode
  points outward, which is the wrong direction. The module validates this.
- Section 3's LGTM services can take names in the same zone at no extra cost.
- The AWS Load Balancer Controller is now a hard dependency of the pipeline, not an
  optional add-on.

## Alternatives considered

| Option | Survives add-on upgrade | Stable across LB replacement | Why not |
|---|---|---|---|
| CoreDNS stub domain on Cluster A | No — add-on rewrites the ConfigMap | Yes | Day-2 upgrades silently break telemetry |
| Hardcode the NLB address | Yes | No — changes on replacement | Breaks on any LB recreate, and the certificate SAN cannot match an IP cleanly |
| Public endpoint + public DNS | Yes | Yes | Rejected by ADR 0002 — telemetry over the internet |
| **Private zone + internal NLB** | Yes | Yes | **Chosen** |
