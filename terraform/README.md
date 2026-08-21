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
    ├── dns-private-zone/   # Route 53 private zone associated with BOTH VPCs (x1)
    ├── aws-lb-controller/  # AWS Load Balancer Controller + its IRSA role    (Cluster B)
    ├── cert-manager/       # cert-manager, issues the gateway certificate    (Cluster B)
    ├── telemetry-gateway/  # Gateway Alloy, internal NLB, TLS + auth         (Cluster B)
    └── telemetry-agent/    # Alloy DaemonSet, collects and ships             (Cluster A)
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

## Usage

### 1. Bootstrap the state backend (once per account)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # set a globally-unique bucket name
terraform init
terraform apply
terraform output backend_config_snippet        # -> paste into envs/prod/backend.hcl
```

### 2. Apply the platform

```bash
cd ../envs/prod
cp backend.hcl.example backend.hcl             # bucket / region / kms_key_id
cp terraform.tfvars.example terraform.tfvars   # ACCOUNT ID + API allow-list CIDRs

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
| 4 x `t3.large` on-demand (2 per cluster) | ~$243 |
| 2 x NAT gateway (`single_nat_gateway = true`) | ~$65 |
| 1 x internal NLB (the telemetry gateway) | ~$17 + LCU |
| Flow logs / CloudWatch / KMS / ECR | ~$5–15 |

The NLB is the only hourly charge the Kubernetes layer adds — raw VPC peering
has none. `make platform-destroy` reclaims it without touching the clusters.

**Idle clusters burn the budget.** `terraform destroy` between test runs. Set
`single_nat_gateway = false` and `node_instance_types = ["t3.medium"]` to trade
HA for spend in the other direction.

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

**Current status.** All three root modules validate; 6 module suites pass (32
assertions); 3 Alloy configs validate against `grafana/alloy:v1.12.0`. Stage 1
last planned **149 resources to add with zero errors** against a live account.
Nothing has been applied — no AWS resources were created.
