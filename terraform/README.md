# Terraform — Multi-Cluster EKS Platform

Foundational IaC for a two-cluster observability platform: an application fleet
(**Cluster A**) shipping telemetry over a private link to a centralized LGTM
stack (**Cluster B**).

> Two stages. `envs/prod` builds the AWS infrastructure; `envs/prod-platform`
> builds the Kubernetes layer on top of it. The recruiter-facing overview and the
> architecture diagram live in the repository root `README.md`.
>
> **Why any of this is shaped the way it is:** [`../docs/adr/`](../docs/README.md).

## Layout

```
terraform/
├── bootstrap/              # Applied ONCE, with local state: creates the S3 state bucket
├── envs/
│   ├── prod/               # STAGE 1 — AWS infrastructure
│   └── prod-platform/      # STAGE 2 — the Kubernetes layer, reads stage 1 via remote state
└── modules/
    ├── vpc/                # VPC, subnets, IGW, NAT, flow logs, endpoints   (instantiated x2)
    ├── security/           # VPC peering + cross-VPC OTLP security groups   (x1)
    ├── eks/                # Cluster, node group, IRSA/OIDC, add-ons        (x2)
    ├── ecr/                # Private registry for images and OCI Helm charts (x1)
    ├── irsa/               # Generic IRSA role factory — one role, one ServiceAccount
    ├── lgtm-storage/       # S3 buckets + per-signal IRSA roles             (x1, stage 1)
    ├── dns-private-zone/   # Route 53 private zone associated with BOTH VPCs (x1)
    ├── aws-lb-controller/  # AWS Load Balancer Controller + its IRSA role    (Cluster B)
    ├── cert-manager/       # cert-manager, issues the gateway certificate    (Cluster B)
    ├── storage-class/      # CSI-backed default StorageClass                 (x2)
    ├── metrics-server/     # Resource metrics API, so an HPA can function    (x2)
    ├── telemetry-gateway/  # Gateway Alloy, internal NLB, TLS + auth         (Cluster B)
    ├── telemetry-agent/    # Alloy DaemonSet, collects and ships             (Cluster A)
    ├── lgtm-backends/      # Mimir, Loki, Tempo on S3                        (Cluster B)
    ├── grafana/            # The single pane of glass                        (Cluster B)
    └── workload-app/       # The instrumented application                    (Cluster A)
```

Modules never call each other. Each root module's `main.tf` is the only place
wiring happens, and it wires exclusively through declared module outputs.

`charts/telemetry-certs/` at the repository root holds the cert-manager issuers
and certificates. They ship as a Helm chart rather than as `kubernetes_manifest`
resources because those need the CRD registered at *plan* time, so a fresh apply
that installs cert-manager and a `Certificate` together cannot plan at all.

### Two stages, and why

The Helm and Kubernetes providers configure themselves from a cluster endpoint
and credentials — values that `envs/prod` creates. Deriving provider config from
resources in the same apply does not plan on green-field and wedges on destroy,
and a failed Helm release would leave the infrastructure state partial. Full
reasoning in [ADR 0008](../docs/adr/0008-two-stage-terraform.md).

## Decisions

| Decision | Rationale |
|---|---|
| **Two VPCs, not one** | Blast radius — the observability plane must outlive the workload plane — and VPC CNI IP exhaustion. Full reasoning in [ADR 0001](../docs/adr/0001-two-vpc-architecture.md). |
| **VPC peering over PrivateLink / public endpoints** | Free to create, fully private, trivial for a 2-VPC single-account topology. Public endpoints were rejected outright (telemetry over the internet). PrivateLink is the right answer once observability moves to its own account. See [ADR 0002](../docs/adr/0002-cross-vpc-telemetry-transport.md). |
| **S3 backend with `use_lockfile = true`** | Terraform 1.10+ native S3 locking via a conditional-write `.tflock` object. No DynamoDB table to bootstrap, secure, pay for, or drift. DynamoDB locking is deprecated in 1.11+. |
| **Nodes in private subnets only** | No node has a public IP or an inbound internet path. Public subnets carry NAT gateways and load balancers, nothing else. |
| **IRSA for everything, node role kept thin** | `AmazonEKS_CNI_Policy` is deliberately *not* on the node role — the VPC CNI gets it through its own IRSA role. IMDS hop limit is 1, so a Pod cannot reach instance metadata and IRSA is the only credential path. |
| **`IMMUTABLE` tags + `scan_on_push`** | A released tag can never be repointed at a different digest, and nothing enters a cluster unscanned. |
| **Grafana Alloy, not the upstream Collector** | Alloy bridges Prometheus scrapes and Loki log tails into OTLP *in-process*, so all three signals leave Cluster A on one connection and the peering link stays at two ports. The upstream Collector would need a Prometheus agent and Promtail beside it. [ADR 0006](../docs/adr/0006-telemetry-agent-selection.md). |
| **Private hosted zone + internal NLB, not a CoreDNS stub** | The two clusters share no DNS namespace. One zone associated with *both* VPCs resolves the gateway below Kubernetes, so an EKS CoreDNS add-on upgrade cannot undo it. [ADR 0007](../docs/adr/0007-cross-cluster-name-resolution.md). |
| **Security group on the NLB, not only the nodes** | NLB `ip` targets do not preserve the client IP by default, so a CIDR rule attached only to nodes never sees Cluster A's address and quietly matches nothing. |
| **Two root modules** | Provider config cannot come from resources in the same apply. [ADR 0008](../docs/adr/0008-two-stage-terraform.md). |
| **Tempo single-binary, not `tempo-distributed`** | One pod instead of six. The distributed chart's ingester, distributor, querier, query-frontend, compactor and metrics-generator each carry their own requests; at this trace volume they buy nothing and the stack no longer fits two 8 GiB nodes. **Both charts are deprecated upstream** in favour of `k8s-monitoring`, so neither is a long-term home — this pins the one a sixth the size. |
| **Mimir keeps one PVC** | The ingester WAL is the single exception to "everything durable lives in S3", and the ingester will not start without it. EKS ships no default StorageClass, so `modules/storage-class` provides a gp3 one; without it the PVCs sit `Pending` and Helm fails with `context deadline exceeded`. [ADR 0010](../docs/adr/0010-cloud-native-storage-and-irsa.md). |

## Usage

### 1. Bootstrap the state backend (once per account)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # set a globally-unique bucket name
terraform init
terraform apply
terraform output backend_config_snippet        # -> paste into envs/prod/backend.hcl
terraform output ci_role_arns                  # -> needed by step 2, below
terraform output github_actions_variables      # -> GitHub Settings -> Variables
```

If CI will ever run this, also create the two **GitHub Environments** now —
`prod-infra` and `prod-platform`, each with at least one **required reviewer**.
The apply and destroy jobs declare them, and the apply role's trust policy is
scoped on the `environment` claim, so the gate is enforced by IAM and not only
by GitHub. An environment that exists without a reviewer gates nothing.

### 2. Apply the platform

Set **`cluster_admin_role_arns`** in the tfvars file before applying — your own
IAM/SSO role plus the `ci-plan` and `ci-apply` ARNs printed in step 1. Each becomes
an EKS access entry granting `cluster-admin` on both clusters, and it is the only
practical way in: without it the clusters answer to nothing but the principal that
ran this apply, stage 2 cannot configure its providers, and repairing it from
outside the cluster needs the very access it is supposed to grant.

```bash
cd ../envs/prod
cp backend.hcl.example backend.hcl             # bucket / region / kms_key_id
cp terraform.tfvars.example terraform.tfvars   # ACCOUNT ID + allow-list CIDRs + admin ARNs

terraform init -backend-config=backend.hcl
terraform fmt -recursive -check
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

### 3. Mirror the third-party charts and images into ECR

Nothing is pulled from a public registry at deploy time
([ADR 0005](../docs/adr/0005-container-supply-chain.md)). This step populates the
`mirror/*` and `charts/*` repositories that stage 2 references, and must happen
**between** the two stages.

```bash
cd ..            # terraform/
make mirror      # versions pinned in ../scripts/mirror-images.sh
```

Re-running is safe: tags are `IMMUTABLE`, so anything already present is skipped
rather than re-pushed.

### 4. Apply the Kubernetes layer

```bash
cd envs/prod-platform
cp backend.hcl.example backend.hcl             # same bucket, different key
cp terraform.tfvars.example terraform.tfvars   # ACCOUNT ID + state bucket

terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan                         # 10-15 min: cert issuance, then the NLB
```

Then verify the pipeline end to end — `make verify` prints the checks with this
deployment's real names substituted in. See
[`../docs/RUNBOOK-telemetry.md`](../docs/RUNBOOK-telemetry.md).

### 5. Get kubeconfig for both clusters

```bash
eval "$(terraform output -raw workload_cluster      | jq -r .kubeconfig)"
eval "$(terraform output -raw observability_cluster | jq -r .kubeconfig)"
kubectl config get-contexts
```

### 6. Tear down (this is a cost-capped account — do it)

**Order matters here more than anywhere else.** Destroying the clusters first
leaves the platform state unable to configure the providers it needs to clean
itself up.

```bash
cd terraform
make platform-destroy   # MUST come first
make destroy
```

## Cost notes

Roughly, per month, in `eu-west-1`, with the committed defaults:

| Item | Cost |
|---|---|
| 2 x EKS control plane | ~$146 |
| 4 x `m7i-flex.large` on-demand (2 per cluster) | ~$280 |
| 2 x NAT gateway (`single_nat_gateway = true`) | ~$65 |
| 1 x internal NLB (the telemetry gateway) | ~$17 + LCU |
| Flow logs / CloudWatch / KMS / ECR | ~$5–15 |

The NLB is the only hourly charge the Kubernetes layer adds — raw VPC peering
has none. `make platform-destroy` reclaims it without touching the clusters.

**Idle clusters burn the budget.** `terraform destroy` between test runs. Set
`single_nat_gateway = false` to trade HA for spend in the other direction.

**Instance type is account-constrained.** An AWS Free Plan account rejects `RunInstances`
for any type that is not free-tier-eligible, and the node group then hangs in `CREATING`
with an empty `health.issues` — the reason appears only in CloudTrail. Check with
`aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`.
`m7i-flex.large` is eligible and gives 2 vCPU / 8 GiB.

## Verification

```bash
make validate         # all three root modules, no credentials needed
make test             # terraform test across every module, offline via mock_provider
make alloy-validate   # renders each .alloy template and validates it with the real binary
```

`make test` is the one that carries weight. Every module ships `.tftest.hcl`
files that run under `mock_provider`, so the suite needs no AWS account: it
asserts that IRSA trust policies pin both `sub` and `aud`, that the gateway
requires auth on *both* listeners, that the agent has exactly one exporter and
verifies its CA, and that no upstream registry appears in any rendered values.

`make alloy-validate` catches what none of the others can. An Alloy config error
survives `terraform plan`, `helm template` and `helm install` alike, and surfaces
only as a `CrashLoopBackOff` on a running cluster. It already caught one:
`otelcol.exporter.debug` is an experimental component, and Alloy refuses to start
unless the stability level admits it.

`make lgtm-validate` renders every LGTM values file against the real upstream charts and
asserts on the resulting manifests. It has caught a bundled Kafka StatefulSet, a persistence
key Helm accepted and ignored, and an image reference that was syntactically valid and
unpullable — none of which any values assertion could see.

**Current status.** All three root modules validate; **12 module suites pass — 81 test cases,
186 assertions**; 3 Alloy configs validate against `grafana/alloy:v1.12.0`; all four Helm value
sets render against their charts.

The platform has been **applied end to end against a live account and torn down again**.
Metrics, logs and traces were verified flowing from Cluster A into Mimir, Loki and Tempo on
Cluster B, with the evidence in [`../docs/proof-of-life/`](../docs/proof-of-life/). Stage 1
last planned **224 resources to add with zero errors**.
