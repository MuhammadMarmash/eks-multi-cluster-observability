# Terraform — Multi-Cluster EKS Platform

Foundational IaC for a two-cluster observability platform: an application fleet
(**Cluster A**) shipping telemetry over a private link to a centralized LGTM
stack (**Cluster B**).

> This is the infrastructure layer only. Helm/GitOps for Online Boutique and the
> LGTM stack live in `../kubernetes`; the recruiter-facing overview and the
> architecture diagram live in the repository root `README.md`.
>
> **Why any of this is shaped the way it is:** [`../docs/adr/`](../docs/README.md).

## Layout

```
terraform/
├── bootstrap/              # Applied ONCE, with local state: creates the S3 state bucket
├── envs/prod/              # The root module you actually run (main.tf, variables.tf, ...)
└── modules/
    ├── vpc/                # VPC, subnets, IGW, NAT, flow logs, endpoints  (instantiated x2)
    ├── security/           # VPC peering + cross-VPC OTLP security groups  (x1)
    ├── eks/                # Cluster, node group, IRSA/OIDC, add-ons        (x2)
    └── ecr/                # Private registry for images and OCI Helm charts (x1)
```

Modules never call each other. `envs/prod/main.tf` is the only place wiring
happens, and it wires exclusively through declared module outputs.

## Decisions

| Decision | Rationale |
|---|---|
| **Two VPCs, not one** | Blast radius — the observability plane must outlive the workload plane — and VPC CNI IP exhaustion. Full reasoning in [ADR 0001](../docs/adr/0001-two-vpc-architecture.md). |
| **VPC peering over PrivateLink / public endpoints** | Free to create, fully private, trivial for a 2-VPC single-account topology. Public endpoints were rejected outright (telemetry over the internet). PrivateLink is the right answer once observability moves to its own account. See [ADR 0002](../docs/adr/0002-cross-vpc-telemetry-transport.md). |
| **S3 backend with `use_lockfile = true`** | Terraform 1.10+ native S3 locking via a conditional-write `.tflock` object. No DynamoDB table to bootstrap, secure, pay for, or drift. DynamoDB locking is deprecated in 1.11+. |
| **Nodes in private subnets only** | No node has a public IP or an inbound internet path. Public subnets carry NAT gateways and load balancers, nothing else. |
| **IRSA for everything, node role kept thin** | `AmazonEKS_CNI_Policy` is deliberately *not* on the node role — the VPC CNI gets it through its own IRSA role. IMDS hop limit is 1, so a Pod cannot reach instance metadata and IRSA is the only credential path. |
| **`IMMUTABLE` tags + `scan_on_push`** | A released tag can never be repointed at a different digest, and nothing enters a cluster unscanned. |

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

### 3. Get kubeconfig for both clusters

```bash
eval "$(terraform output -raw workload_cluster      | jq -r .kubeconfig)"
eval "$(terraform output -raw observability_cluster | jq -r .kubeconfig)"
kubectl config get-contexts
```

### 4. Tear down (this is a cost-capped account — do it)

```bash
terraform destroy
```

## Cost notes

Roughly, per month, in `eu-west-1`, with the committed defaults:

| Item | Cost |
|---|---|
| 2 x EKS control plane | ~$146 |
| 4 x `t3.large` on-demand (2 per cluster) | ~$243 |
| 2 x NAT gateway (`single_nat_gateway = true`) | ~$65 |
| Flow logs / CloudWatch / KMS / ECR | ~$5–15 |

**Idle clusters burn the budget.** `terraform destroy` between test runs. Set
`single_nat_gateway = false` and `node_instance_types = ["t3.medium"]` to trade
HA for spend in the other direction.

## Verification status

`terraform validate` passes for `bootstrap/` and `envs/prod/`, and
`terraform plan` against a live AWS account plans **149 resources to add with
zero errors**. Nothing has been applied — no AWS resources were created.
