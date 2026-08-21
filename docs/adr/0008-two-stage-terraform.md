# ADR 0008 — Two Terraform root modules: infrastructure, then the Kubernetes layer

**Status:** Accepted
**Date:** 2026-08-21
**Implemented by:** `terraform/envs/prod`, `terraform/envs/prod-platform`

## Context

The Helm and Kubernetes providers configure themselves from a cluster endpoint, a CA
certificate and a credential. Every one of those comes from resources that
`terraform/envs/prod` creates.

Putting the Helm releases in that same root module is the obvious move and the wrong one.

## Decision

A **second root module**, `terraform/envs/prod-platform`, with its own state key in the
same S3 bucket. It reads `envs/prod` through `terraform_remote_state` and looks the cluster
CA and OIDC issuer up live with `data "aws_eks_cluster"`.

Three reasons, in order of how much they hurt:

1. **Provider configuration from same-apply resources does not plan.** On a green-field
   run the cluster endpoint is unknown at plan time, so Terraform cannot configure the
   provider, so it cannot plan the releases. On destroy it is worse: the provider is
   reconfigured from state that is being torn down underneath it, and the run wedges.
2. **Blast radius.** A Helm release that fails — a bad chart value, an image that will not
   pull — cannot leave the *infrastructure* state partially applied. The two failure
   domains are genuinely separate and now their states are too.
3. **It is the shape CI needs anyway.** Section 4 wants ordered jobs. Two root modules are
   two jobs, the second gated on the first, with `make mirror` between them.

## Consequences

- **Apply order is load-bearing and must be documented.** `envs/prod`, then `make mirror`,
  then `envs/prod-platform`. The `terraform.tfvars.example` in the platform root says so at
  the top, and `docs/RUNBOOK-telemetry.md` says it again.
- **Destroy order is the reverse, and getting it wrong is worse than getting apply wrong.**
  `make platform-destroy` must run *before* `make destroy`: once the clusters are gone, the
  platform root's providers cannot configure themselves and the state cannot be cleaned up
  without manual surgery.
- Two states means two locks, two `init` invocations and two `backend.hcl` files.
- `envs/prod` needs no new outputs. Cluster CA data and the OIDC issuer are looked up live
  rather than plumbed through state, so the two roots stay loosely coupled and the values
  cannot go stale between applies.

## Alternatives considered

| Option | Plans on green-field | Destroys cleanly | Why not |
|---|---|---|---|
| One root module | No | No | The provider-from-same-apply problem, in both directions |
| One root, `-target` the clusters first | Yes, with ceremony | No | `-target` is a break-glass tool; making it the routine path hides drift |
| GitOps controller (Argo CD / Flux) | Yes | Yes | **The honest long-term answer.** Terraform bootstraps the controller, everything else syncs from git. Rejected for now only on scope: it is a whole control plane to build, secure and debug for five Helm releases. Revisit when the platform outgrows a handful |
| **Two root modules** | Yes | Yes | **Chosen** |
