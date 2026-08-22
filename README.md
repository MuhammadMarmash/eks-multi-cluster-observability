# Multi-Cluster Observability Platform on AWS EKS

[![CI](https://github.com/MuhammadMarmash/eks-multi-cluster-observability/actions/workflows/ci.yaml/badge.svg)](https://github.com/MuhammadMarmash/eks-multi-cluster-observability/actions/workflows/ci.yaml)
[![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A5_1.11-844FBA?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![AWS](https://img.shields.io/badge/AWS-EKS_%7C_S3_%7C_IRSA-FF9900?logo=amazonwebservices&logoColor=white)](https://aws.amazon.com/eks/)
[![Grafana](https://img.shields.io/badge/Stack-Loki_Grafana_Tempo_Mimir-F46800?logo=grafana&logoColor=white)](https://grafana.com/oss/)
[![OIDC](https://img.shields.io/badge/CI_auth-OIDC_%C2%B7_zero_static_keys-2ea44f?logo=githubactions&logoColor=white)](.github/workflows/deploy.yaml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Two EKS clusters, two VPCs, one private telemetry pipeline.** An application fleet ships
metrics, logs and traces across a VPC peering link to a centralised **LGTM stack** whose
durable data lives entirely in **S3** — so the observability cluster can be destroyed and
rebuilt without losing a single sample.

Every layer is Terraform. Nothing is pulled from a public registry at deploy time, no
component holds a long-lived AWS key, and the CI pipeline cannot apply anything until a
human has approved it — enforced by an **IAM trust policy**, not just a workflow setting.

---

## Architecture

```mermaid
flowchart LR
  subgraph A["vpc-workload &nbsp;·&nbsp; 10.0.0.0/16"]
    direction TB
    BQ["<b>Online Boutique</b><br/>11 OTLP-instrumented services"]
    AG["<b>Alloy DaemonSet</b><br/>OTLP receiver · kubelet scrape<br/>pod-log tail → all OTLP"]
    BQ -- OTLP --> AG
  end

  subgraph B["vpc-observability &nbsp;·&nbsp; 10.1.0.0/16"]
    direction TB
    NLB["<b>internal NLB</b><br/>:4317 / :4318<br/><i>SG: workload CIDR only</i>"]
    GW["<b>Gateway Alloy</b><br/>terminates TLS + auth"]
    MI["Mimir"]
    LO["Loki"]
    TE["Tempo"]
    GF["<b>Grafana</b><br/>traces ⇄ logs ⇄ metrics"]
    NLB --> GW
    GW -- metrics --> MI
    GW -- logs --> LO
    GW -- traces --> TE
    MI & LO & TE --> GF
  end

  S3[("<b>Amazon S3</b><br/>3 buckets · SSE-S3<br/>per-signal lifecycle")]
  ECR[("<b>Amazon ECR</b><br/>every image + chart<br/>mirrored, immutable tags")]
  R53["Route 53 private zone<br/><i>associated with BOTH VPCs</i>"]

  AG == "OTLP/gRPC over TLS<br/><b>VPC peering</b> · 2 ports" ==> NLB
  MI & LO & TE -. "IRSA · no static keys" .-> S3
  R53 -.->|resolves| NLB
  ECR -.->|pull| A
  ECR -.->|pull| B
```

**The data path in one line:** app → local Alloy → *(TLS + basic auth over peering)* →
gateway Alloy → Mimir / Loki / Tempo → S3, with Grafana reading back over HTTP.

---

## Tech stack

**Infrastructure**
Terraform ≥ 1.11 · AWS EKS · VPC Peering · Route 53 private zones · Network Load Balancer ·
S3 with native state locking · KMS

**Kubernetes & observability**
Grafana Alloy · Mimir · Loki · Tempo · Grafana · cert-manager · AWS Load Balancer Controller ·
metrics-server · Helm

**Security & supply chain**
IRSA (IAM Roles for Service Accounts) · GitHub OIDC federation · Amazon ECR with immutable
tags and scan-on-push · TLS terminated in-cluster by cert-manager

**CI/CD**
GitHub Actions · OIDC (no static credentials) · GitHub Environments as approval gates ·
`terraform test` with `mock_provider`

---

## What's interesting here

- **Zero long-lived credentials, anywhere.** Loki, Mimir and Tempo reach S3 through **IRSA**;
  GitHub Actions reaches AWS through **OIDC federation**. There is no access key in the repo,
  in a Secret, or in GitHub — by construction, not by policy.
- **The approval gate is enforced by AWS, not GitHub.** The CI apply role's trust policy pins
  `repo:OWNER/REPO:environment:prod-infra`, so a workflow edited to skip the protected
  Environment **cannot obtain credentials at all**. ([ADR 0008](docs/adr/0008-two-stage-terraform.md))
- **Three IAM roles, one per signal.** Loki's role cannot read a single metric or trace. Each
  policy names every permitted action — no `s3:*`, no wildcard resources.
  ([ADR 0010](docs/adr/0010-cloud-native-storage-and-irsa.md))
- **Cross-cluster DNS solved below Kubernetes.** One Route 53 private zone associated with
  *both* VPCs, so no CoreDNS stub domain exists for an EKS add-on upgrade to silently
  overwrite. ([ADR 0007](docs/adr/0007-cross-cluster-name-resolution.md))
- **Exactly two ports cross the peering link.** Alloy converts Prometheus scrapes and pod-log
  tails into OTLP *in-process*, so all three signals leave on one authenticated connection.
  ([ADR 0006](docs/adr/0006-telemetry-agent-selection.md))
- **69 assertions that need no AWS account.** Every module ships `terraform test` files
  running under `mock_provider`, plus scripts that render every Helm values file against the
  real upstream charts and validate every Alloy config with the real Alloy binary.

---

## Design decisions

Ten ADRs record what was chosen, what it costs, and what was rejected.
Index: [`docs/README.md`](docs/README.md)

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-two-vpc-architecture.md) | Two VPCs — blast radius and VPC CNI IP exhaustion |
| [0002](docs/adr/0002-cross-vpc-telemetry-transport.md) | VPC peering over PrivateLink and public endpoints |
| [0003](docs/adr/0003-s3-native-state-locking.md) | S3 backend with native locking, no DynamoDB |
| [0004](docs/adr/0004-cluster-security-posture.md) | Private nodes, IRSA-only credentials, closed IMDS |
| [0005](docs/adr/0005-container-supply-chain.md) | Private ECR, immutable tags, scan-on-push |
| [0006](docs/adr/0006-telemetry-agent-selection.md) | Grafana Alloy as the unified agent |
| [0007](docs/adr/0007-cross-cluster-name-resolution.md) | Internal NLB + dual-associated private zone |
| [0008](docs/adr/0008-two-stage-terraform.md) | Two Terraform roots — infrastructure, then Kubernetes |
| [0009](docs/adr/0009-workload-application-source.md) | The workload app, pinned by repository |
| [0010](docs/adr/0010-cloud-native-storage-and-irsa.md) | Three S3 buckets, three IRSA roles, per-signal lifecycle |

**Runbooks**
[Telemetry pipeline](docs/RUNBOOK-telemetry.md) — deploy, verify, troubleshoot ·
[Day-2 operations](docs/runbooks/day-2-ops.md) — EKS upgrades and Mimir autoscaling

---

## Repository layout

```
terraform/
  bootstrap/            state bucket + GitHub OIDC provider and CI roles  (applied once, by hand)
  envs/prod/            STAGE 1 — VPCs, EKS, ECR, S3 buckets, IRSA roles
  envs/prod-platform/   STAGE 2 — the Kubernetes layer, reads stage 1 via remote state
  modules/              14 modules; none calls another
charts/telemetry-certs/ cert-manager issuers and certificates
scripts/                ECR mirroring · Alloy config validation · Helm values validation
.github/workflows/      ci · deploy · destroy
docs/adr/               10 architecture decision records
docs/runbooks/          Day-2 operations
```

---

## Getting started

**Prerequisites** — Terraform ≥ 1.11 · AWS CLI v2 · Helm 3 · Docker · `kubectl` · `jq` ·
an AWS account you are willing to spend roughly $8–10/day in.

### 1. Bootstrap (once per account)

Creates the state bucket, the GitHub OIDC provider and the three CI roles.

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # bucket name + owner/repo
terraform init && terraform apply
terraform output github_actions_variables      # paste into GitHub → Settings → Variables
```

### 2. Deploy — three stages, and the order is load-bearing

```bash
cd terraform
cp envs/prod/backend.hcl.example envs/prod/backend.hcl
cp envs/prod/terraform.tfvars.example envs/prod/terraform.tfvars

make init && make plan && make apply    # 1. clusters, buckets, IAM   (~20 min)
make mirror                             # 2. charts + images into ECR
make platform-init
make platform-plan && make platform-apply   # 3. Kubernetes layer     (~15 min)

make verify                             # prints the end-to-end checks, with real names
```

Why each gate exists: **stage 2's providers configure themselves from clusters that must
already exist**, and `helm_release` **resolves charts at plan time**, so an unmirrored chart
fails the *plan*, not just the apply.

### 3. See it

```bash
terraform -chdir=envs/prod-platform output -raw grafana_admin_password
kubectl -n lgtm port-forward svc/grafana 3000:80
```

### 4. Tear down — reverse order

```bash
make platform-destroy   # MUST come first
make destroy
```

Destroying the clusters first leaves the platform state unable to configure the providers it
needs to clean itself up. `terraform destroy` will also **refuse** to delete non-empty LGTM
buckets — that is [ADR 0010](docs/adr/0010-cloud-native-storage-and-irsa.md) working as
designed.

### Verify without an AWS account

```bash
cd terraform
make validate         # all three root modules
make test             # 69 assertions across 10 modules, offline via mock_provider
make alloy-validate   # renders each .alloy template, validates with the real Alloy binary
make lgtm-validate    # renders LGTM values against the real upstream charts
```

---

## CI/CD

Three workflows. Every job authenticates with a short-lived **OIDC token** — there is no AWS
key in GitHub Secrets.

```mermaid
flowchart LR
  V["validate<br/><i>no credentials</i>"] --> PI["plan-infra"]
  PI --> GI{{"prod-infra<br/>approval"}}
  GI --> AI["apply-infra"]
  AI --> M["mirror → ECR"]
  M --> PP["plan-platform"]
  PP --> GP{{"prod-platform<br/>approval"}}
  GP --> AP["apply-platform"]
```

| Workflow | Trigger | Purpose |
|---|---|---|
| [`ci.yaml`](.github/workflows/ci.yaml) | PR, branch push | fmt · validate · 69 assertions · chart renders · Alloy validation · infra plan |
| [`deploy.yaml`](.github/workflows/deploy.yaml) | push to `main`, manual | the gated chain above |
| [`destroy.yaml`](.github/workflows/destroy.yaml) | manual only | teardown, platform first, typed confirmation |

Three roles: **plan** (read-only), **apply** (only assumable from a protected Environment),
**ecr-push** (`main` only — `mirror-images.sh` is in-tree, so a PR must not decide what lands
in the registry both clusters pull from). Actions are pinned by **commit SHA**, not tag.

**No `tfplan` is ever uploaded as an artifact.** A saved plan holds secrets in plaintext and
artifacts are readable by anyone with repo access, so the apply job re-plans under a
concurrency lock.

---

## Proof of life

> A Grafana dashboard in Cluster B showing traces and metrics originating from the Boutique
> services in Cluster A. Screenshot to be added after the first full apply.

---

## Lessons learned

**1. `t3.large` → `t3.medium` cost 3× more memory than the spec sheet says.**
EKS reserves `255Mi + 11Mi × max_pods` per node. Prefix delegation raises max_pods to **110**,
so kube-reserved is **1465 MiB per node regardless of instance size** — 18% of a t3.large but
**36% of a t3.medium**. Two t3.medium nodes yield **4.75 GiB allocatable, not the ~6.5 GiB** a
naive reading gives, and the LGTM stack does not fit. The fix was three nodes rather than two,
which still costs less than the two t3.large it replaced. Since both instance types have the
same 2 vCPU, the downgrade cost memory only.

**2. Helm ignores keys it does not recognise — silently.**
Rendering every values file against the real upstream charts (`make lgtm-validate`) caught
three defects no unit test could:

- `mimir-distributed` ships `kafka.enabled: true`, rendering an entire **Kafka StatefulSet with
  a 5Gi PVC** for an ingest path nothing here uses.
- The Loki chart's key is `persistence.volumeClaimsEnabled`, **not** `persistence.enabled`. My
  values *looked* correct while the StatefulSets kept their PVCs.
- Setting `image.registry: ""` makes charts emit `"" + "/" + repository` — a **leading slash**
  and an unpullable reference. It passes every values assertion and fails as
  `ImagePullBackOff` on a live cluster.

The lesson generalised: **assert on rendered output, not on your own inputs.** The same
principle caught `otelcol.exporter.debug` being an *experimental* component that Alloy refuses
to start with at the default stability level.

**3. A security group can be perfectly written and still match nothing.**
The peering security group restricting ingest to the workload VPC CIDR was attached to
Cluster B's **nodes**. But the NLB uses `ip` target type, for which **client-IP preservation is
off by default** — traffic reaching the pod appears to come from the load balancer, not from
Cluster A. The CIDR rule was real, correct, and quietly matched nothing. It had to move onto
the **NLB itself**.

**4. Writing the Day-2 runbook found two gaps that contradicted claims the platform made.**
The gateway Alloy had no PodDisruptionBudget and no anti-affinity, so a single node drain could
evict both replicas and take ingest to zero — undermining the "bounded telemetry gap" the
design depended on. And metrics-server was not installed anywhere, which does not degrade an
HPA so much as prevent one from ever functioning. Both are now fixed. **Documenting a system
honestly is a test of it.**

---

## Cost

Roughly per month in `eu-west-1` with committed defaults, if left running:

| Item | Cost |
|---|---|
| 2 × EKS control plane | ~$146 |
| 6 × `t3.medium` (3 per cluster) | ~$200 |
| 2 × NAT gateway | ~$65 |
| 1 × internal NLB | ~$17 |
| S3 · ECR · KMS · flow logs | ~$10–20 |

**Idle clusters burn the budget.** `make platform-destroy` reclaims the NLB and the LGTM stack
without touching the clusters; `make destroy` takes the rest.

---

## License

[MIT](LICENSE) © Mohammad Marmash
