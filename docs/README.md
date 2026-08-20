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

## Related

- [`../terraform/README.md`](../terraform/README.md) — module layout, runbook, cost table
- [`../FINAL_PROJECT_MISSION.md`](../FINAL_PROJECT_MISSION.md) — the original brief
