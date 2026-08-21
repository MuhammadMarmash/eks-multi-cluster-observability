# Documentation

## Architecture Decision Records

The reasoning behind the platform's structural choices. Each record states the context,
the decision, what it costs us, and what was rejected.

| ADR | Decision |
|---|---|
| [0001](adr/0001-two-vpc-architecture.md) | Two VPCs, one per cluster — blast radius and VPC CNI IP exhaustion |
| [0002](adr/0002-cross-vpc-telemetry-transport.md) | VPC peering for the telemetry pipeline, over PrivateLink and public endpoints |
| [0003](adr/0003-s3-native-state-locking.md) | S3 backend with native locking, no DynamoDB |
| [0004](adr/0004-cluster-security-posture.md) | EKS security posture — private nodes, IRSA-only credentials, closed IMDS |
| [0005](adr/0005-container-supply-chain.md) | Private ECR registry with immutable tags and scan-on-push |
| [0006](adr/0006-telemetry-agent-selection.md) | Grafana Alloy as the unified telemetry agent, over the upstream Collector plus two more agents |
| [0007](adr/0007-cross-cluster-name-resolution.md) | Internal NLB plus a dual-associated private zone, over CoreDNS stub domains |
| [0008](adr/0008-two-stage-terraform.md) | Two Terraform root modules — infrastructure, then the Kubernetes layer |

## Related

- [`RUNBOOK-telemetry.md`](RUNBOOK-telemetry.md) — deploy, verify and troubleshoot the telemetry pipeline
- [`superpowers/specs/2026-08-21-cross-cluster-telemetry-pipeline-design.md`](superpowers/specs/2026-08-21-cross-cluster-telemetry-pipeline-design.md) — the pipeline's design
- [`../terraform/README.md`](../terraform/README.md) — module layout, runbook, cost table
- [`../FINAL_PROJECT_MISSION.md`](../FINAL_PROJECT_MISSION.md) — the original brief
