# ADR 0004 — EKS cluster security posture

**Status:** Accepted
**Date:** 2026-08-20
**Implemented by:** `terraform/modules/eks`

## Context

Both clusters are provisioned from one module, so every security control decided here
applies uniformly to the workload and observability planes. The defaults EKS gives you are
not the defaults we want.

## Decisions

### Nodes live in private subnets, always

The control-plane cross-account ENIs and every managed node are placed in private subnets.
No node carries a public IP or has an inbound path from the internet. Public subnets exist
only for NAT gateways and internet-facing load balancers.

### IRSA is the only credential path for Pods

The IAM OIDC provider is created for both clusters, so a ServiceAccount token can be
exchanged for scoped AWS credentials via `sts:AssumeRoleWithWebIdentity`. Every IRSA trust
policy pins **two** conditions:

- `sub` — the exact `namespace:serviceaccount` allowed to assume the role.
- `aud` — `sts.amazonaws.com`.

Omitting either is the classic IRSA misconfiguration that lets any ServiceAccount in the
cluster assume any role.

This is the mechanism behind every "no long-lived access keys" claim in the architecture:
Loki, Mimir, Tempo and the EBS CSI driver all reach S3 and EBS through it.

### The node role is kept deliberately thin

`AmazonEKS_CNI_Policy` is **not** attached to the node role. The VPC CNI receives its
ENI/IP mutation rights through its own IRSA role bound to the `aws-node` ServiceAccount, so
a Pod that somehow reaches node credentials cannot manipulate ENIs. The node role carries
only `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`,
`AmazonSSMManagedInstanceCore`, and a narrowly scoped log-write policy.

Likewise, the control-plane role gets `AmazonEKSClusterPolicy` and
`AmazonEKSVPCResourceController` only. The EKS Auto Mode policies are omitted because this
platform manages its own node groups and add-ons — attaching them would be dead privilege.

### IMDS is closed to Pods

Nodes launch from an explicit launch template with `http_tokens = "required"` (IMDSv2 only)
and **`http_put_response_hop_limit = 1`**. A hop limit of 1 means a container in a Pod
network namespace cannot reach the instance metadata service at all, which closes the
classic "Pod steals the node role's credentials" escalation path and makes IRSA the only
way for a Pod to obtain AWS credentials.

*Operational caveat:* a third-party chart that expects node-level IMDS credentials will
fail. Raising the limit to 2 is a one-variable change, and should be a conscious, reviewed
decision.

### Secrets are envelope-encrypted

Without `encryption_config`, Kubernetes Secrets are only base64-encoded at rest in
EKS-managed etcd. Each cluster gets a customer-managed, rotating KMS key, so every Secret
is encrypted with a wrapped data key and every decrypt is a CloudTrail event.

### The audit trail is on by default

`api`, `audit`, `authenticator`, `controllerManager` and `scheduler` logs ship to a
CloudWatch log group that Terraform owns (so retention is managed and `destroy` cleans it
up). `audit` and `authenticator` are non-negotiable for answering "who did what".

### Access is IAM-native

`authentication_mode = "API_AND_CONFIG_MAP"` enables EKS access entries while staying
compatible with any legacy `aws-auth` tooling. Cluster-admin grants are declared as a list
of role ARNs and applied identically to both clusters.

### SSH is replaced by SSM

No key pairs, no port 22, no bastion. `AmazonSSMManagedInstanceCore` on the node role means
Session Manager access, and every session is a CloudTrail event.

## Consequences

- The public API endpoint defaults to enabled so CI and operators can reach the clusters
  without a VPN. **It must be paired with a real `cluster_public_access_cidrs`
  allow-list** — the shipped default of `0.0.0.0/0` leaves the (still authenticated) API
  server reachable from the whole internet. Closing it to `false` once a VPN or SSM bastion
  exists is the intended end state.
- IMDS hop limit 1 will break charts that assume node credentials. That is the trade
  being made.
- Per-cluster KMS keys are ~$1/month each and cannot be deleted for 30 days.
