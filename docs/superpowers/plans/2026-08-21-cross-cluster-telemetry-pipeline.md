# Cross-Cluster Telemetry Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship metrics, logs and traces from Cluster A to Cluster B over the VPC peering link, as OTLP, with TLS and authentication terminating at a gateway inside Cluster B.

**Architecture:** A Grafana Alloy DaemonSet on Cluster A converts Prometheus scrapes and pod log tails into OTLP in-process, so all three signals leave on one connection to `gateway.observability.internal:4317`. That name resolves through a Route 53 private hosted zone associated with both VPCs to an internal NLB in Cluster B, which passes TCP through to a Gateway Alloy deployment that terminates TLS and basic auth and fans out locally. The Kubernetes layer lives in a second Terraform root module that reads the existing `envs/prod` state.

**Tech Stack:** Terraform >= 1.11, AWS provider ~> 6.0, Helm provider ~> 3.0, Kubernetes provider ~> 2.38, Grafana Alloy, cert-manager, AWS Load Balancer Controller, Amazon ECR (OCI charts + mirrored images).

**Spec:** [`docs/superpowers/specs/2026-08-21-cross-cluster-telemetry-pipeline-design.md`](../specs/2026-08-21-cross-cluster-telemetry-pipeline-design.md)

## Global Constraints

- **Terraform version floor is `>= 1.11.0`.** Every `versions.tf` repeats this exact string. Native S3 state locking (`use_lockfile`) requires it; see ADR 0003.
- **Provider pins:** `hashicorp/aws ~> 6.0`, `hashicorp/helm ~> 3.0`, `hashicorp/kubernetes ~> 2.38`, `hashicorp/random ~> 3.6`, `hashicorp/time ~> 0.12`.
- **Helm provider v3 syntax only.** `kubernetes = { ... }` is a nested *attribute* (`=`, not a block), `registries = [ { ... } ]` is a list attribute, and `set = [ { name, value } ]` is a list of objects. v2 block syntax will not parse.
- **Chart values are always built with `yamlencode()`**, never string-templated YAML. Only the `.alloy` config itself uses `templatefile()`. This is what keeps embedded multi-line configs from breaking on indentation.
- **Every module is testable offline.** No module may use an AWS data source whose value an assertion depends on — `mock_provider "aws" {}` returns generated values for data sources, so trust policies are built with `jsonencode()` in `locals`, not `data.aws_iam_policy_document`. This is a deliberate deviation from `modules/eks`, noted in each file's header comment.
- **Namespaces are created by Terraform, never by a Helm chart.** Every `helm_release` sets `create_namespace = false`.
- **Nothing is pulled from a public registry at deploy time** (ADR 0005). Every chart and image reference resolves to the ECR registry, supplied as a variable.
- **`terraform/envs/prod` is not restructured.** The only change to it is adding mirror repositories to the `ecr_repositories` variable default and its `terraform.tfvars.example`.
- **Only ports 4317 and 4318 cross the peering link.** No task may add a rule to `modules/security`.
- **Commit authorship is the repo's own** — do not add any AI attribution trailer, matching the existing history. Conventional commit prefixes, lowercase subject, imperative mood.

---

## File Structure

```
terraform/
  Makefile                                   MODIFY  add test/mirror targets, platform root
  envs/
    prod/
      variables.tf                           MODIFY  mirror repos in ecr_repositories default
      terraform.tfvars.example               MODIFY  document the mirror repos
    prod-platform/                           CREATE  the Kubernetes layer root module
      versions.tf  providers.tf  data.tf
      main.tf  variables.tf  locals.tf  outputs.tf
      backend.tf  backend.hcl.example  terraform.tfvars.example
  modules/
    irsa/                                    CREATE  generic IRSA role factory
      main.tf variables.tf outputs.tf versions.tf tests/irsa.tftest.hcl
    dns-private-zone/                        CREATE  Route 53 PHZ + multi-VPC association
      main.tf variables.tf outputs.tf versions.tf tests/zone.tftest.hcl
    aws-lb-controller/                       CREATE  IRSA + Helm release
      main.tf variables.tf outputs.tf versions.tf iam-policy.json tests/controller.tftest.hcl
    cert-manager/                            CREATE  Helm release
      main.tf variables.tf outputs.tf versions.tf tests/cert-manager.tftest.hcl
    telemetry-gateway/                       CREATE  Cluster B Alloy gateway + NLB + certs
      main.tf variables.tf outputs.tf versions.tf config.alloy.tftpl tests/gateway.tftest.hcl
    telemetry-agent/                         CREATE  Cluster A Alloy DaemonSet
      main.tf variables.tf outputs.tf versions.tf config.alloy.tftpl tests/agent.tftest.hcl
charts/
  telemetry-certs/                           CREATE  ClusterIssuers + Certificates
    Chart.yaml values.yaml templates/*.yaml
scripts/
  mirror-images.sh                           CREATE  ECR mirroring, idempotent
docs/
  adr/0006-telemetry-agent-selection.md      CREATE
  adr/0007-cross-cluster-name-resolution.md  CREATE
  adr/0008-two-stage-terraform.md            CREATE
  README.md                                  MODIFY  ADR catalog rows
  RUNBOOK-telemetry.md                       CREATE  deploy + verify + troubleshoot
terraform/README.md                          MODIFY  module table, two-stage apply
```

**Boundaries.** `modules/irsa` knows nothing about Kubernetes. `modules/telemetry-agent` knows nothing about Cluster B beyond a hostname, a CA PEM and a credential — all inputs. `modules/telemetry-gateway` knows nothing about Cluster A at all. The root module is the only place the two sides meet, which is the same rule `envs/prod` already follows.

---

### Task 1: Generic IRSA role factory

The reusable piece every later task and all of Section 3 needs. Built first because `modules/aws-lb-controller` consumes it, and because it establishes the offline test cycle the whole plan depends on.

**Files:**
- Create: `terraform/modules/irsa/versions.tf`
- Create: `terraform/modules/irsa/variables.tf`
- Create: `terraform/modules/irsa/main.tf`
- Create: `terraform/modules/irsa/outputs.tf`
- Test: `terraform/modules/irsa/tests/irsa.tftest.hcl`
- Modify: `terraform/Makefile` (add `test` target)

**Interfaces:**
- Consumes: nothing.
- Produces: module outputs `role_arn` (string), `role_name` (string), `assume_role_policy_json` (string). Inputs: `role_name`, `oidc_provider_arn`, `oidc_provider_host`, `namespace`, `service_account`, `managed_policy_arns` (list(string), default `[]`), `inline_policy_json` (string, default `null`), `description`, `tags`.

- [ ] **Step 1: Write the failing test**

Create `terraform/modules/irsa/tests/irsa.tftest.hcl`:

```hcl
mock_provider "aws" {}

variables {
  role_name          = "role-test-cluster-alb"
  oidc_provider_arn  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"
  oidc_provider_host = "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"
  namespace          = "kube-system"
  service_account    = "aws-load-balancer-controller"
}

run "trust_policy_pins_both_sub_and_aud" {
  command = plan

  assert {
    condition     = strcontains(output.assume_role_policy_json, "system:serviceaccount:kube-system:aws-load-balancer-controller")
    error_message = "Trust policy must pin the exact namespace/ServiceAccount in the sub condition."
  }

  assert {
    condition     = strcontains(output.assume_role_policy_json, "sts.amazonaws.com")
    error_message = "Trust policy must pin the aud condition to sts.amazonaws.com; omitting it is the classic IRSA misconfiguration."
  }

  assert {
    condition     = strcontains(output.assume_role_policy_json, "sts:AssumeRoleWithWebIdentity")
    error_message = "Trust policy must allow sts:AssumeRoleWithWebIdentity."
  }
}

run "rejects_wildcard_service_account" {
  command = plan

  variables {
    service_account = "*"
  }

  expect_failures = [var.service_account]
}

run "attaches_every_managed_policy" {
  command = plan

  variables {
    managed_policy_arns = [
      "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
      "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
    ]
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.managed) == 2
    error_message = "One attachment per managed policy ARN."
  }
}

run "inline_policy_is_optional" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.inline) == 0
    error_message = "No inline policy resource when inline_policy_json is null."
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd terraform/modules/irsa && terraform init -backend=false -input=false && terraform test
```

Expected: FAIL. With no `.tf` files present Terraform reports that the configuration is empty / the referenced resources and variables do not exist.

- [ ] **Step 3: Write the implementation**

`terraform/modules/irsa/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

`terraform/modules/irsa/variables.tf`:

```hcl
###############################################################################
# modules/irsa — input variables
###############################################################################

variable "role_name" {
  description = "Name of the IAM role. Must be unique within the account."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider. Comes from the eks module's oidc_provider_arn output."
  type        = string
}

variable "oidc_provider_host" {
  description = "OIDC issuer without the https:// scheme — the exact string used as the condition key prefix. Comes from the eks module's oidc_provider_host output."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of the ServiceAccount allowed to assume this role."
  type        = string
}

variable "service_account" {
  description = "Name of the ServiceAccount allowed to assume this role."
  type        = string

  validation {
    condition     = !strcontains(var.service_account, "*")
    error_message = "service_account must be an exact name. A wildcard would let any ServiceAccount in the namespace assume this role."
  }
}

variable "managed_policy_arns" {
  description = "AWS managed or customer managed policy ARNs to attach."
  type        = list(string)
  default     = []
}

variable "inline_policy_json" {
  description = "Optional inline policy document. Use for policies that exist only for this role, such as the AWS Load Balancer Controller policy."
  type        = string
  default     = null
}

variable "description" {
  description = "Human-readable description recorded on the role."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
```

`terraform/modules/irsa/main.tf`:

```hcl
###############################################################################
# modules/irsa
#
# One IAM role assumable by exactly one Kubernetes ServiceAccount, via the
# cluster's OIDC provider. The trust policy pins BOTH the `sub` (exact
# namespace/ServiceAccount) and the `aud` (sts.amazonaws.com) condition;
# omitting either is the classic IRSA misconfiguration.
#   docs/adr/0004-cluster-security-posture.md
#
# The trust policy is built with jsonencode() rather than
# data.aws_iam_policy_document — unlike modules/eks — so that the document is
# a plain string the module can assert on under `terraform test` with
# mock_provider, where every AWS data source returns a generated value.
###############################################################################

locals {
  tags = merge(
    var.tags,
    {
      "Module"    = "irsa"
      "ManagedBy" = "terraform"
    },
  )

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${var.oidc_provider_host}:sub" = "system:serviceaccount:${var.namespace}:${var.service_account}"
            "${var.oidc_provider_host}:aud" = "sts.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  description        = var.description != "" ? var.description : "IRSA role for ${var.namespace}/${var.service_account}"
  assume_role_policy = local.assume_role_policy

  tags = merge(local.tags, {
    "Name"           = var.role_name
    "ServiceAccount" = "${var.namespace}/${var.service_account}"
  })
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  count = var.inline_policy_json == null ? 0 : 1

  name   = "${var.role_name}-inline"
  role   = aws_iam_role.this.id
  policy = var.inline_policy_json
}
```

`terraform/modules/irsa/outputs.tf`:

```hcl
###############################################################################
# modules/irsa — outputs
###############################################################################

output "role_arn" {
  description = "ARN of the IRSA role. Annotate the ServiceAccount with eks.amazonaws.com/role-arn set to this."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the IRSA role."
  value       = aws_iam_role.this.name
}

output "assume_role_policy_json" {
  description = "The rendered trust policy. Exposed so the module's own tests, and any policy check in CI, can assert on the sub and aud conditions."
  value       = local.assume_role_policy
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd terraform/modules/irsa && terraform init -backend=false -input=false && terraform test
```

Expected: PASS, 4 run blocks, `Success! 4 passed, 0 failed.`

- [ ] **Step 5: Add the `test` target to the Makefile**

In `terraform/Makefile`, add `test` to the `.PHONY` line and append this target after `validate`:

```makefile
test: ## Run terraform test for every module that has a tests/ directory
	@for m in modules/*/; do \
	  if [ -d "$$m/tests" ]; then \
	    printf '\033[36m==> %s\033[0m\n' "$$m"; \
	    ( cd "$$m" && terraform init -backend=false -input=false >/dev/null && terraform test ) || exit 1; \
	  fi; \
	done
```

- [ ] **Step 6: Verify the Makefile target works**

```bash
cd terraform && make test
```

Expected: `==> modules/irsa/` followed by `Success! 4 passed, 0 failed.`

- [ ] **Step 7: Format and commit**

```bash
cd terraform && terraform fmt -recursive && cd .. && git add terraform/modules/irsa terraform/Makefile
git commit -m "feat(terraform): add generic IRSA role factory

One role, one ServiceAccount, both sub and aud pinned. Section 3 needs
four of these for Loki, Mimir, Tempo and Grafana, and the AWS Load
Balancer Controller needs one now, so it is worth having exactly one
place where an IRSA trust policy is written.

The trust policy is built with jsonencode rather than
aws_iam_policy_document so the module can be tested offline: under
mock_provider every AWS data source returns a generated value, which
would make an assertion on the policy meaningless.

Adds a make test target that runs terraform test across every module
that ships tests."
```

---

### Task 2: ECR mirror repositories and the mirroring script

ADR 0005 says nothing is pulled from a public source at deploy time. This task creates the repositories and the tool, and locks the naming convention that every later values file references.

**Files:**
- Modify: `terraform/envs/prod/variables.tf` (the `ecr_repositories` variable)
- Modify: `terraform/envs/prod/terraform.tfvars.example`
- Create: `scripts/mirror-images.sh`
- Modify: `terraform/Makefile` (add `mirror` target)

**Interfaces:**
- Consumes: nothing.
- Produces: the repository names every later task references — `mirror/grafana/alloy`, `mirror/eks/aws-load-balancer-controller`, `mirror/jetstack/cert-manager-controller`, `mirror/jetstack/cert-manager-cainjector`, `mirror/jetstack/cert-manager-webhook`, `mirror/jetstack/cert-manager-startupapicheck`, `charts/alloy`, `charts/aws-load-balancer-controller`, `charts/cert-manager`. Pinned versions live in `scripts/mirror-images.sh` and are copied verbatim into `envs/prod-platform/terraform.tfvars.example` in Task 8.

- [ ] **Step 1: Read the current variable, then extend its default**

```bash
grep -n -A 30 'variable "ecr_repositories"' terraform/envs/prod/variables.tf
```

Add these entries to the `default` map of `ecr_repositories`, preserving whatever is already there:

```hcl
    "mirror/grafana/alloy" = {
      description = "Mirrored Grafana Alloy image — the telemetry agent on A and the gateway on B"
    }
    "mirror/eks/aws-load-balancer-controller" = {
      description = "Mirrored AWS Load Balancer Controller image"
    }
    "mirror/jetstack/cert-manager-controller" = {
      description = "Mirrored cert-manager controller image"
    }
    "mirror/jetstack/cert-manager-cainjector" = {
      description = "Mirrored cert-manager cainjector image"
    }
    "mirror/jetstack/cert-manager-webhook" = {
      description = "Mirrored cert-manager webhook image"
    }
    "mirror/jetstack/cert-manager-startupapicheck" = {
      description = "Mirrored cert-manager startupapicheck image"
    }
    "charts/alloy" = {
      description = "Grafana Alloy OCI Helm chart"
    }
    "charts/aws-load-balancer-controller" = {
      description = "AWS Load Balancer Controller OCI Helm chart"
    }
    "charts/cert-manager" = {
      description = "cert-manager OCI Helm chart"
    }
```

- [ ] **Step 2: Write the mirroring script**

Create `scripts/mirror-images.sh`:

```bash
#!/usr/bin/env bash
#
# Mirror every third-party chart and image the platform layer needs into ECR.
#
# ADR 0005 forbids pulling from public registries at deploy time. This script
# is the only place a public registry is contacted, and it runs on an
# engineer's or CI runner's machine, never on a cluster.
#
# Idempotent against ECR's IMMUTABLE tag policy: a tag that already exists is
# skipped rather than re-pushed, so re-running after a partial failure is safe.
#
# Usage: AWS_REGION=eu-west-1 AWS_PROFILE=... ./scripts/mirror-images.sh
set -euo pipefail

REGION="${AWS_REGION:-eu-west-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# --- Pinned versions. Bump here and nowhere else. ----------------------------
ALLOY_CHART_VERSION="1.4.0"
ALLOY_IMAGE_TAG="v1.12.0"
ALB_CHART_VERSION="1.13.4"
ALB_IMAGE_TAG="v2.13.4"
CERT_MANAGER_VERSION="v1.19.1"

log()  { printf '\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }
}
require aws
require docker
require helm

# Returns 0 when the tag already exists in ECR.
tag_exists() {
  local repo="$1" tag="$2"
  aws ecr describe-images \
    --region "$REGION" \
    --repository-name "$repo" \
    --image-ids "imageTag=$tag" \
    >/dev/null 2>&1
}

mirror_image() {
  local src="$1" repo="$2" tag="$3"
  if tag_exists "$repo" "$tag"; then
    warn "skip ${repo}:${tag} (already present)"
    return 0
  fi
  log "image ${src} -> ${REGISTRY}/${repo}:${tag}"
  docker pull --platform linux/amd64 "$src"
  docker tag "$src" "${REGISTRY}/${repo}:${tag}"
  docker push "${REGISTRY}/${repo}:${tag}"
}

mirror_chart() {
  local chart_ref="$1" version="$2" repo="$3"
  if tag_exists "$repo" "$version"; then
    warn "skip chart ${repo}:${version} (already present)"
    return 0
  fi
  log "chart ${chart_ref}:${version} -> oci://${REGISTRY}/${repo%/*}"
  local workdir
  workdir="$(mktemp -d)"
  helm pull "$chart_ref" --version "$version" --destination "$workdir"
  helm push "$workdir"/*.tgz "oci://${REGISTRY}/${repo%/*}"
  rm -rf "$workdir"
}

log "authenticating docker and helm against ${REGISTRY}"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"
aws ecr get-login-password --region "$REGION" \
  | helm registry login --username AWS --password-stdin "$REGISTRY"

log "adding upstream chart repositories"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo update >/dev/null

mirror_image "docker.io/grafana/alloy:${ALLOY_IMAGE_TAG}" \
             "mirror/grafana/alloy" "${ALLOY_IMAGE_TAG}"
mirror_image "public.ecr.aws/eks/aws-load-balancer-controller:${ALB_IMAGE_TAG}" \
             "mirror/eks/aws-load-balancer-controller" "${ALB_IMAGE_TAG}"

for component in controller cainjector webhook startupapicheck; do
  mirror_image "quay.io/jetstack/cert-manager-${component}:${CERT_MANAGER_VERSION}" \
               "mirror/jetstack/cert-manager-${component}" "${CERT_MANAGER_VERSION}"
done

mirror_chart "grafana/alloy"                       "${ALLOY_CHART_VERSION}" "charts/alloy"
mirror_chart "eks/aws-load-balancer-controller"    "${ALB_CHART_VERSION}"   "charts/aws-load-balancer-controller"
mirror_chart "jetstack/cert-manager"               "${CERT_MANAGER_VERSION}" "charts/cert-manager"

log "done. registry: ${REGISTRY}"
```

- [ ] **Step 3: Make it executable and verify it passes shellcheck-style syntax validation**

```bash
cd /home/muhammad/devops_practice/devops-project3
chmod +x scripts/mirror-images.sh
bash -n scripts/mirror-images.sh && echo "syntax OK"
```

Expected: `syntax OK`. This is the test — the script talks to AWS, so it cannot be run in CI without credentials, but a syntax error must never reach a runner.

- [ ] **Step 4: Add the `mirror` target to the Makefile**

Add `mirror` to `.PHONY` and append:

```makefile
mirror: ## Mirror third-party charts and images into ECR (ADR 0005). Needs AWS credentials.
	../scripts/mirror-images.sh
```

- [ ] **Step 5: Document the repositories in the tfvars example**

Append to `terraform/envs/prod/terraform.tfvars.example`, under the ECR section:

```hcl
# Mirror repositories for the platform layer are part of the ecr_repositories
# default in variables.tf. Populate them before the first prod-platform apply:
#
#   cd terraform && make mirror
#
# Versions are pinned in scripts/mirror-images.sh. Because tags are IMMUTABLE,
# re-running the script skips anything already present rather than failing.
```

- [ ] **Step 6: Verify the root module still validates**

```bash
cd terraform && terraform fmt -recursive && make validate
```

Expected: `Success! The configuration is valid.` for both `envs/prod` and `bootstrap`.

- [ ] **Step 7: Commit**

```bash
cd /home/muhammad/devops_practice/devops-project3
git add terraform/envs/prod/variables.tf terraform/envs/prod/terraform.tfvars.example scripts/mirror-images.sh terraform/Makefile
git commit -m "feat(ecr): mirror the platform layer's charts and images

ADR 0005 says nothing is pulled from a public source at deploy time,
which has to include the third-party pieces the telemetry pipeline needs:
Alloy, cert-manager and the AWS Load Balancer Controller, as both images
and OCI charts.

The script pins every version in one place and skips anything already in
ECR, so it is safe to re-run after a partial failure — which matters
because the repositories enforce immutable tags and a re-push would
otherwise fail."
```

---

### Task 3: Route 53 private hosted zone

The half of the DNS answer that lives below Kubernetes. Creating the zone and associating it with *both* VPCs is what makes `gateway.observability.internal` resolvable from Cluster A at all.

**Files:**
- Create: `terraform/modules/dns-private-zone/versions.tf`
- Create: `terraform/modules/dns-private-zone/variables.tf`
- Create: `terraform/modules/dns-private-zone/main.tf`
- Create: `terraform/modules/dns-private-zone/outputs.tf`
- Test: `terraform/modules/dns-private-zone/tests/zone.tftest.hcl`

**Interfaces:**
- Consumes: nothing.
- Produces: outputs `zone_id` (string), `zone_name` (string). Inputs: `zone_name`, `primary_vpc_id`, `additional_vpc_ids` (list(string), default `[]`), `tags`.

- [ ] **Step 1: Write the failing test**

Create `terraform/modules/dns-private-zone/tests/zone.tftest.hcl`:

```hcl
mock_provider "aws" {}

variables {
  zone_name          = "observability.internal"
  primary_vpc_id     = "vpc-0aaaaaaaaaaaaaaaa"
  additional_vpc_ids = ["vpc-0bbbbbbbbbbbbbbbb"]
}

run "creates_a_private_zone_named_as_requested" {
  command = plan

  assert {
    condition     = aws_route53_zone.this.name == "observability.internal"
    error_message = "Zone name must match the requested name exactly."
  }

  assert {
    condition     = length(aws_route53_zone.this.vpc) == 1
    error_message = "Exactly one vpc block belongs on the zone; every other VPC is attached with aws_route53_zone_association."
  }
}

run "associates_every_additional_vpc" {
  command = plan

  assert {
    condition     = length(aws_route53_zone_association.additional) == 1
    error_message = "One association per additional VPC. Without the workload VPC association the gateway name does not resolve from Cluster A at all."
  }
}

run "works_with_no_additional_vpcs" {
  command = plan

  variables {
    additional_vpc_ids = []
  }

  assert {
    condition     = length(aws_route53_zone_association.additional) == 0
    error_message = "An empty additional_vpc_ids list must produce no associations."
  }
}

run "rejects_a_public_looking_zone_name" {
  command = plan

  variables {
    zone_name = "observability.example.com"
  }

  expect_failures = [var.zone_name]
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd terraform/modules/dns-private-zone && terraform init -backend=false -input=false && terraform test
```

Expected: FAIL — empty configuration, the referenced resources do not exist.

- [ ] **Step 3: Write the implementation**

`terraform/modules/dns-private-zone/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

`terraform/modules/dns-private-zone/variables.tf`:

```hcl
###############################################################################
# modules/dns-private-zone — input variables
###############################################################################

variable "zone_name" {
  description = <<-EOT
    Name of the private hosted zone, e.g. "observability.internal". Use a
    reserved-looking suffix such as .internal: a name that could plausibly
    exist in public DNS will resolve publicly from anywhere the zone is not
    associated, which fails open rather than closed.
  EOT
  type        = string

  validation {
    condition     = endswith(var.zone_name, ".internal") || endswith(var.zone_name, ".local")
    error_message = "zone_name must end in .internal or .local so it can never collide with a public name."
  }
}

variable "primary_vpc_id" {
  description = "VPC that owns the zone. Conventionally the VPC the records point into — here, the observability VPC."
  type        = string
}

variable "additional_vpc_ids" {
  description = <<-EOT
    Every other VPC that must be able to resolve names in this zone. The
    workload VPC belongs here: without its association, a query from Cluster A
    leaks past the VPC resolver and returns NXDOMAIN.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
```

`terraform/modules/dns-private-zone/main.tf`:

```hcl
###############################################################################
# modules/dns-private-zone
#
# A Route 53 private hosted zone associated with more than one VPC. This is
# the mechanism that lets a pod in Cluster A resolve a name that points into
# Cluster B, with no CoreDNS configuration on either cluster: the query
# forwards to the VPC resolver, which is authoritative for this zone because
# the querying VPC is associated with it.
#
#   docs/adr/0007-cross-cluster-name-resolution.md
###############################################################################

locals {
  tags = merge(
    var.tags,
    {
      "Module"    = "dns-private-zone"
      "ManagedBy" = "terraform"
    },
  )
}

resource "aws_route53_zone" "this" {
  name          = var.zone_name
  comment       = "Private zone for cross-cluster service discovery"
  force_destroy = false

  vpc {
    vpc_id = var.primary_vpc_id
  }

  # Associations made by aws_route53_zone_association are invisible to this
  # resource's own vpc blocks. Without this, every plan would try to remove
  # them and the two resources would fight forever. This is the documented
  # pattern for a multi-VPC private zone.
  lifecycle {
    ignore_changes = [vpc]
  }

  tags = merge(local.tags, { "Name" = var.zone_name })
}

resource "aws_route53_zone_association" "additional" {
  for_each = toset(var.additional_vpc_ids)

  zone_id = aws_route53_zone.this.zone_id
  vpc_id  = each.value
}
```

`terraform/modules/dns-private-zone/outputs.tf`:

```hcl
###############################################################################
# modules/dns-private-zone — outputs
###############################################################################

output "zone_id" {
  description = "Hosted zone ID. Pass to whichever module creates records in the zone."
  value       = aws_route53_zone.this.zone_id
}

output "zone_name" {
  description = "Zone name, without a trailing dot."
  value       = var.zone_name
}

output "associated_vpc_ids" {
  description = "Every VPC that can resolve names in this zone, primary first."
  value       = concat([var.primary_vpc_id], var.additional_vpc_ids)
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd terraform/modules/dns-private-zone && terraform init -backend=false -input=false && terraform test
```

Expected: PASS, `Success! 4 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
cd /home/muhammad/devops_practice/devops-project3
cd terraform && terraform fmt -recursive && cd ..
git add terraform/modules/dns-private-zone
git commit -m "feat(terraform): add multi-VPC private hosted zone module

The gateway in Cluster B needs a name that a pod in Cluster A can
resolve. Associating one private zone with both VPCs does that entirely
inside Route 53 and the VPC resolver, with no CoreDNS stub domain and no
ConfigMap edit on either cluster — deliberately, because CoreDNS surgery
is the first thing an EKS add-on upgrade undoes.

The zone keeps one vpc block and ignores changes to it; every other VPC
attaches through aws_route53_zone_association. Mixing the two without
ignore_changes makes each plan try to undo the other."
```

---

### Task 4: AWS Load Balancer Controller on Cluster B

Without this, a `Service` of type `LoadBalancer` gets a Classic LB from the legacy in-tree provider — no `ip` target type, no security group control, none of what §4 of the spec depends on.

**Files:**
- Create: `terraform/modules/aws-lb-controller/versions.tf`
- Create: `terraform/modules/aws-lb-controller/variables.tf`
- Create: `terraform/modules/aws-lb-controller/main.tf`
- Create: `terraform/modules/aws-lb-controller/outputs.tf`
- Create: `terraform/modules/aws-lb-controller/iam-policy.json` (downloaded, pinned)
- Test: `terraform/modules/aws-lb-controller/tests/controller.tftest.hcl`

**Interfaces:**
- Consumes: `modules/irsa` — inputs `role_name`, `oidc_provider_arn`, `oidc_provider_host`, `namespace`, `service_account`, `inline_policy_json`, `description`, `tags`; output `role_arn`.
- Produces: outputs `irsa_role_arn` (string), `service_account_name` (string, always `aws-load-balancer-controller`), `rendered_values` (string), `release_name` (string).

- [ ] **Step 1: Download the pinned upstream IAM policy**

The policy is roughly 250 lines of AWS actions and is maintained upstream; copying it by hand is how it drifts.

```bash
cd /home/muhammad/devops_practice/devops-project3
mkdir -p terraform/modules/aws-lb-controller
curl -fsSL -o terraform/modules/aws-lb-controller/iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.4/docs/install/iam_policy.json
jq -e '.Statement | length > 0' terraform/modules/aws-lb-controller/iam-policy.json
```

Expected: a number greater than 0 printed, confirming the file is valid JSON with statements. The `v2.13.4` tag matches `ALB_IMAGE_TAG` in `scripts/mirror-images.sh` — if you bump one, bump both.

- [ ] **Step 2: Write the failing test**

Create `terraform/modules/aws-lb-controller/tests/controller.tftest.hcl`:

```hcl
mock_provider "aws" {}
mock_provider "helm" {}

variables {
  cluster_name       = "obs-platform-prod-observability"
  vpc_id             = "vpc-0bbbbbbbbbbbbbbbb"
  region             = "eu-west-1"
  oidc_provider_arn  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"
  oidc_provider_host = "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"
  chart_repository   = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts"
  chart_version      = "1.13.4"
  image_repository   = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/mirror/eks/aws-load-balancer-controller"
  image_tag          = "v2.13.4"
}

run "values_pin_the_cluster_vpc_and_region" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_values, "clusterName: obs-platform-prod-observability")
    error_message = "The controller refuses to start without the exact cluster name."
  }

  assert {
    condition     = strcontains(output.rendered_values, "vpcId: vpc-0bbbbbbbbbbbbbbbb")
    error_message = "Pinning vpcId saves the controller an IMDS lookup and makes the plan self-documenting."
  }
}

run "image_comes_from_ecr_not_upstream" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_values, "123456789012.dkr.ecr.eu-west-1.amazonaws.com/mirror/eks/aws-load-balancer-controller")
    error_message = "ADR 0005 forbids pulling from a public registry at deploy time."
  }

  assert {
    condition     = !strcontains(output.rendered_values, "public.ecr.aws")
    error_message = "No upstream registry may appear in the rendered values."
  }
}

run "webhook_certificate_does_not_depend_on_cert_manager" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_values, "enableCertManager: false")
    error_message = "The chart must self-sign its webhook certificate. Depending on cert-manager here creates a deploy-order cycle, since cert-manager's own webhook needs a working cluster."
  }
}

run "service_account_is_annotated_with_the_irsa_role" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_values, "eks.amazonaws.com/role-arn")
    error_message = "Without the role-arn annotation the controller falls back to the node role and cannot create load balancers."
  }

  assert {
    condition     = output.service_account_name == "aws-load-balancer-controller"
    error_message = "The ServiceAccount name is pinned in the IRSA trust policy and must not drift."
  }
}

run "release_is_pinned_and_does_not_create_its_namespace" {
  command = plan

  assert {
    condition     = helm_release.this.version == "1.13.4"
    error_message = "Chart version must be pinned, never floating."
  }

  assert {
    condition     = helm_release.this.create_namespace == false
    error_message = "Terraform owns namespaces; charts never create them."
  }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd terraform/modules/aws-lb-controller && terraform init -backend=false -input=false && terraform test
```

Expected: FAIL — no configuration.

- [ ] **Step 4: Write the implementation**

`terraform/modules/aws-lb-controller/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}
```

`terraform/modules/aws-lb-controller/variables.tf`:

```hcl
###############################################################################
# modules/aws-lb-controller — input variables
###############################################################################

variable "cluster_name" {
  description = "EKS cluster this controller manages load balancers for. The controller will not start without it."
  type        = string
}

variable "vpc_id" {
  description = "VPC the cluster runs in. Pinning it avoids an IMDS lookup at startup."
  type        = string
}

variable "region" {
  description = "AWS region the cluster runs in."
  type        = string
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider ARN of the cluster, for the IRSA trust policy."
  type        = string
}

variable "oidc_provider_host" {
  description = "OIDC issuer host without the scheme, for the IRSA condition keys."
  type        = string
}

variable "namespace" {
  description = "Namespace to install into. Must already exist — Terraform owns namespaces."
  type        = string
  default     = "kube-system"
}

variable "chart_repository" {
  description = "OCI registry holding the mirrored chart, e.g. oci://<account>.dkr.ecr.<region>.amazonaws.com/charts."
  type        = string
}

variable "chart_version" {
  description = "Exact chart version. Never floating — a surprise controller upgrade takes the ingress path with it."
  type        = string
}

variable "image_repository" {
  description = "ECR repository holding the mirrored controller image."
  type        = string
}

variable "image_tag" {
  description = "Exact image tag. Keep in step with the tag pinned in scripts/mirror-images.sh."
  type        = string
}

variable "replicas" {
  description = "Controller replicas. Two gives leader-election failover; one is enough for a lab."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags merged onto every AWS resource in this module."
  type        = map(string)
  default     = {}
}
```

`terraform/modules/aws-lb-controller/main.tf`:

```hcl
###############################################################################
# modules/aws-lb-controller
#
# The AWS Load Balancer Controller, so that a Service of type LoadBalancer
# becomes an NLB with `ip` targets and a security group we choose, rather than
# the Classic LB the legacy in-tree cloud provider would create.
#
# The telemetry gateway's internal NLB depends on all three of those
# capabilities:
#   docs/adr/0007-cross-cluster-name-resolution.md
#
# enableCertManager is false on purpose. The chart can self-sign its admission
# webhook certificate, and making it wait on cert-manager creates a deploy
# ordering cycle for no security gain — the webhook is cluster-internal.
###############################################################################

locals {
  service_account_name = "aws-load-balancer-controller"

  values = {
    clusterName = var.cluster_name
    region      = var.region
    vpcId       = var.vpc_id

    replicaCount = var.replicas

    image = {
      repository = var.image_repository
      tag        = var.image_tag
    }

    serviceAccount = {
      create = true
      name   = local.service_account_name
      annotations = {
        "eks.amazonaws.com/role-arn" = module.irsa.role_arn
      }
    }

    enableCertManager = false

    # The controller is cluster infrastructure: it must keep running while the
    # nodes it manages are under pressure.
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
  }
}

module "irsa" {
  source = "../irsa"

  role_name          = "role-${var.cluster_name}-alb-controller"
  oidc_provider_arn  = var.oidc_provider_arn
  oidc_provider_host = var.oidc_provider_host
  namespace          = var.namespace
  service_account    = local.service_account_name
  description        = "AWS Load Balancer Controller for ${var.cluster_name}"

  # The upstream policy, pinned to the controller version in
  # scripts/mirror-images.sh. Bump both together.
  inline_policy_json = file("${path.module}/iam-policy.json")

  tags = var.tags
}

resource "helm_release" "this" {
  name             = "aws-load-balancer-controller"
  namespace        = var.namespace
  repository       = var.chart_repository
  chart            = "aws-load-balancer-controller"
  version          = var.chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [yamlencode(local.values)]
}
```

`terraform/modules/aws-lb-controller/outputs.tf`:

```hcl
###############################################################################
# modules/aws-lb-controller — outputs
###############################################################################

output "irsa_role_arn" {
  description = "ARN of the controller's IRSA role."
  value       = module.irsa.role_arn
}

output "service_account_name" {
  description = "ServiceAccount the controller runs as. Pinned in the IRSA trust policy."
  value       = local.service_account_name
}

output "release_name" {
  description = "Helm release name. Depend on this from any module that creates a Service of type LoadBalancer."
  value       = helm_release.this.name
}

output "rendered_values" {
  description = "The values document handed to Helm. Exposed so tests can assert on image origin and configuration without an apply."
  value       = yamlencode(local.values)
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd terraform/modules/aws-lb-controller && terraform init -backend=false -input=false && terraform test
```

Expected: PASS, `Success! 5 passed, 0 failed.`

- [ ] **Step 6: Commit**

```bash
cd /home/muhammad/devops_practice/devops-project3
cd terraform && terraform fmt -recursive && cd ..
git add terraform/modules/aws-lb-controller
git commit -m "feat(terraform): add AWS Load Balancer Controller module

The telemetry gateway needs an internal NLB with ip targets and a
security group of our choosing. The legacy in-tree cloud provider gives
a Classic LB and none of those three, so the controller is a hard
dependency of the pipeline rather than a nicety.

The IAM policy is the upstream document pinned to v2.13.4 and committed
verbatim rather than retyped, because a hand-maintained copy drifts
silently and the failure mode is a load balancer that never reconciles.

enableCertManager is false: the chart self-signs its own webhook
certificate, and making it wait on cert-manager would create a deploy
ordering cycle for a cluster-internal webhook."
```

---

### Task 5: cert-manager and the certificate chart

Produces the trust material: a self-signed root CA in Cluster B, a server certificate for the gateway, and a CA bundle that Cluster A can actually verify against. The custom resources ship as a local Helm chart rather than `kubernetes_manifest` because `kubernetes_manifest` needs the CRD registered at *plan* time, so a fresh apply that installs cert-manager and a `Certificate` together cannot plan.

**Files:**
- Create: `charts/telemetry-certs/Chart.yaml`
- Create: `charts/telemetry-certs/values.yaml`
- Create: `charts/telemetry-certs/templates/bootstrap-issuer.yaml`
- Create: `charts/telemetry-certs/templates/ca-certificate.yaml`
- Create: `charts/telemetry-certs/templates/ca-issuer.yaml`
- Create: `charts/telemetry-certs/templates/gateway-certificate.yaml`
- Create: `terraform/modules/cert-manager/{versions,variables,main,outputs}.tf`
- Test: `terraform/modules/cert-manager/tests/cert-manager.tftest.hcl`

**Interfaces:**
- Consumes: nothing.
- Produces: `modules/cert-manager` outputs `namespace` (string), `release_name` (string), `rendered_values` (string). The chart is consumed by Task 6 through the path `charts/telemetry-certs`, with values `certManagerNamespace`, `gatewayNamespace`, `gatewayDnsName`, `caCommonName`, `caSecretName`, `caIssuerName`, `gatewaySecretName`, `duration`, `renewBefore`.

- [ ] **Step 1: Write the failing chart test**

Create `charts/telemetry-certs/test.sh` and make it executable:

```bash
#!/usr/bin/env bash
#
# Render the chart and assert on the output. `helm template` is the only test
# that catches a malformed Certificate before cert-manager rejects it at
# admission time, twenty minutes into an apply.
set -euo pipefail
cd "$(dirname "$0")"

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

helm lint . --set gatewayDnsName=gateway.observability.internal

helm template certs . \
  --set certManagerNamespace=cert-manager \
  --set gatewayNamespace=telemetry \
  --set gatewayDnsName=gateway.observability.internal \
  > "$OUT"

check() {
  local description="$1" pattern="$2"
  if grep -qE "$pattern" "$OUT"; then
    printf '  ok   %s\n' "$description"
  else
    printf '  FAIL %s (no match for /%s/)\n' "$description" "$pattern" >&2
    exit 1
  fi
}

refute() {
  local description="$1" pattern="$2"
  if grep -qE "$pattern" "$OUT"; then
    printf '  FAIL %s (unexpected match for /%s/)\n' "$description" "$pattern" >&2
    exit 1
  fi
  printf '  ok   %s\n' "$description"
}

check  "bootstrap issuer is selfSigned"        'selfSigned: \{\}'
check  "CA certificate is marked isCA"         'isCA: true'
check  "CA issuer reads the CA secret"         'ca:\s*$'
check  "gateway cert carries the exact SAN"    '- gateway\.observability\.internal'
check  "gateway cert lands in its namespace"   'namespace: telemetry'
check  "CA material stays in cert-manager ns"  'namespace: cert-manager'
check  "gateway cert renews before expiry"     'renewBefore:'
check  "server auth usage is requested"        '- server auth'
refute "no Secret is templated by this chart"  'kind: Secret'

printf 'chart ok\n'
```

```bash
chmod +x charts/telemetry-certs/test.sh
```

- [ ] **Step 2: Run the chart test to verify it fails**

```bash
./charts/telemetry-certs/test.sh
```

Expected: FAIL — `Error: Chart.yaml file is missing`.

- [ ] **Step 3: Write the chart**

`charts/telemetry-certs/Chart.yaml`:

```yaml
apiVersion: v2
name: telemetry-certs
description: >-
  Self-signed CA and the gateway server certificate for the cross-cluster
  telemetry pipeline. Ships as a chart rather than as Terraform
  kubernetes_manifest resources because those require the cert-manager CRDs to
  be registered at plan time.
type: application
version: 0.1.0
appVersion: "1.0"
```

`charts/telemetry-certs/values.yaml`:

```yaml
# Namespace cert-manager runs in. A ClusterIssuer of type `ca` reads its
# signing secret from cert-manager's own namespace, not from the namespace of
# the Certificate it signs, so the CA material has to live here.
certManagerNamespace: cert-manager

# Namespace the telemetry gateway runs in. Created by Terraform, never here.
gatewayNamespace: telemetry

# The name Cluster A connects to. Must match the Route 53 record exactly, or
# TLS verification fails on the SAN even though the connection succeeds.
gatewayDnsName: gateway.observability.internal

bootstrapIssuerName: telemetry-selfsigned-bootstrap
caIssuerName: telemetry-ca
caCommonName: telemetry-pipeline-ca
caSecretName: telemetry-ca-key-pair
gatewaySecretName: telemetry-gateway-tls

# The CA outlives the leaf by a wide margin so leaf rotation never trips over
# CA expiry. Both are cert-manager durations, not Kubernetes ones.
caDuration: 87600h    # 10 years
caRenewBefore: 8760h  # 1 year
duration: 2160h       # 90 days
renewBefore: 360h     # 15 days
```

`charts/telemetry-certs/templates/bootstrap-issuer.yaml`:

```yaml
# Bootstraps the chain. Exists only to sign the CA certificate below; nothing
# else may ever be issued from it.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: {{ .Values.bootstrapIssuerName }}
  labels:
    app.kubernetes.io/part-of: telemetry-pipeline
spec:
  selfSigned: {}
```

`charts/telemetry-certs/templates/ca-certificate.yaml`:

```yaml
# The root of trust for the whole pipeline. Its public half is what Terraform
# copies into Cluster A so the agent can verify the gateway for real.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .Values.caCommonName }}
  namespace: {{ .Values.certManagerNamespace }}
  labels:
    app.kubernetes.io/part-of: telemetry-pipeline
spec:
  isCA: true
  commonName: {{ .Values.caCommonName }}
  secretName: {{ .Values.caSecretName }}
  duration: {{ .Values.caDuration }}
  renewBefore: {{ .Values.caRenewBefore }}
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: {{ .Values.bootstrapIssuerName }}
    kind: ClusterIssuer
    group: cert-manager.io
```

`charts/telemetry-certs/templates/ca-issuer.yaml`:

```yaml
# Signs the gateway's server certificate. A ClusterIssuer rather than an
# Issuer so Section 3's LGTM components can be given certificates from the
# same CA without duplicating the material into each namespace.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: {{ .Values.caIssuerName }}
  labels:
    app.kubernetes.io/part-of: telemetry-pipeline
spec:
  ca:
    secretName: {{ .Values.caSecretName }}
```

`charts/telemetry-certs/templates/gateway-certificate.yaml`:

```yaml
# The gateway's server certificate. The SAN must equal the Route 53 record
# exactly: Cluster A verifies against it, and a mismatch fails the handshake
# after the connection has already succeeded, which reads like a network fault
# and is not one.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: telemetry-gateway
  namespace: {{ .Values.gatewayNamespace }}
  labels:
    app.kubernetes.io/part-of: telemetry-pipeline
spec:
  commonName: {{ .Values.gatewayDnsName }}
  dnsNames:
    - {{ .Values.gatewayDnsName }}
  secretName: {{ .Values.gatewaySecretName }}
  duration: {{ .Values.duration }}
  renewBefore: {{ .Values.renewBefore }}
  usages:
    - server auth
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  issuerRef:
    name: {{ .Values.caIssuerName }}
    kind: ClusterIssuer
    group: cert-manager.io
```

- [ ] **Step 4: Run the chart test to verify it passes**

```bash
cd /home/muhammad/devops_practice/devops-project3 && ./charts/telemetry-certs/test.sh
```

Expected: nine `ok` lines then `chart ok`.

- [ ] **Step 5: Write the failing Terraform test**

Create `terraform/modules/cert-manager/tests/cert-manager.tftest.hcl`:

```hcl
mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  chart_repository = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts"
  chart_version    = "v1.19.1"
  image_registry   = "123456789012.dkr.ecr.eu-west-1.amazonaws.com"
}

run "installs_crds_with_the_chart" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_values, "crds:")
    error_message = "The CRDs must ship with the release. Installing them separately means a destroy leaves orphaned Certificates behind."
  }
}

run "every_component_image_comes_from_ecr" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_values, "mirror/jetstack/cert-manager-controller")
    error_message = "Controller image must resolve to ECR."
  }

  assert {
    condition     = strcontains(output.rendered_values, "mirror/jetstack/cert-manager-cainjector")
    error_message = "cainjector image must resolve to ECR."
  }

  assert {
    condition     = strcontains(output.rendered_values, "mirror/jetstack/cert-manager-webhook")
    error_message = "webhook image must resolve to ECR."
  }

  assert {
    condition     = strcontains(output.rendered_values, "mirror/jetstack/cert-manager-startupapicheck")
    error_message = "startupapicheck image must resolve to ECR. It is easy to forget and it is the one that blocks the release from ever reporting ready."
  }

  assert {
    condition     = !strcontains(output.rendered_values, "quay.io")
    error_message = "No upstream registry may appear in the rendered values."
  }
}

run "terraform_owns_the_namespace" {
  command = plan

  assert {
    condition     = kubernetes_namespace_v1.this.metadata[0].name == "cert-manager"
    error_message = "The namespace is a Terraform resource."
  }

  assert {
    condition     = helm_release.this.create_namespace == false
    error_message = "The chart must not create its own namespace."
  }
}

run "release_waits_for_readiness" {
  command = plan

  assert {
    condition     = helm_release.this.wait == true
    error_message = "Reading the CA secret in the next module races cert-manager unless this release blocks until its webhook is serving."
  }
}
```

- [ ] **Step 6: Run the Terraform test to verify it fails**

```bash
cd terraform/modules/cert-manager && terraform init -backend=false -input=false && terraform test
```

Expected: FAIL — no configuration.

- [ ] **Step 7: Write the cert-manager module**

`terraform/modules/cert-manager/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }
}
```

`terraform/modules/cert-manager/variables.tf`:

```hcl
###############################################################################
# modules/cert-manager — input variables
###############################################################################

variable "namespace" {
  description = <<-EOT
    Namespace cert-manager runs in. Also the cluster resource namespace: a
    ClusterIssuer of type `ca` reads its signing secret from here regardless of
    where the Certificate it signs lives. Changing this means changing
    charts/telemetry-certs' certManagerNamespace to match.
  EOT
  type        = string
  default     = "cert-manager"
}

variable "chart_repository" {
  description = "OCI registry holding the mirrored chart."
  type        = string
}

variable "chart_version" {
  description = "Exact chart version, matching CERT_MANAGER_VERSION in scripts/mirror-images.sh."
  type        = string
}

variable "image_registry" {
  description = "ECR registry hostname, e.g. <account>.dkr.ecr.<region>.amazonaws.com. Component repository paths are appended to it."
  type        = string
}

variable "labels" {
  description = "Labels applied to the namespace."
  type        = map(string)
  default     = {}
}
```

`terraform/modules/cert-manager/main.tf`:

```hcl
###############################################################################
# modules/cert-manager
#
# cert-manager exists here for one reason: to issue the telemetry gateway's
# server certificate from a CA whose public half Cluster A can be given, so
# that the agent verifies the gateway for real rather than skipping
# verification.
#
# Why not ACM: a Route 53 *private* zone offers no way to prove domain
# ownership for a public ACM certificate, and ACM Private CA bills roughly
# $400/month against this project's $50 budget.
#   docs/superpowers/specs/2026-08-21-cross-cluster-telemetry-pipeline-design.md
###############################################################################

locals {
  values = {
    crds = {
      # Ship the CRDs with the release rather than installing them out of band.
      # Installed separately, a destroy leaves orphaned Certificates that block
      # namespace deletion.
      enabled = true
      keep    = false
    }

    image           = { repository = "${var.image_registry}/mirror/jetstack/cert-manager-controller" }
    cainjector      = { image = { repository = "${var.image_registry}/mirror/jetstack/cert-manager-cainjector" } }
    webhook         = { image = { repository = "${var.image_registry}/mirror/jetstack/cert-manager-webhook" } }
    startupapicheck = { image = { repository = "${var.image_registry}/mirror/jetstack/cert-manager-startupapicheck" } }

    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = merge(var.labels, {
      "app.kubernetes.io/part-of" = "telemetry-pipeline"
    })
  }
}

resource "helm_release" "this" {
  name             = "cert-manager"
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  repository       = var.chart_repository
  chart            = "cert-manager"
  version          = var.chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true

  # Non-negotiable: the next module reads a Secret that cert-manager has to
  # have issued. Without wait, that read races the webhook coming up and the
  # first apply fails on an empty CA bundle.
  wait    = true
  timeout = 600

  values = [yamlencode(local.values)]
}
```

`terraform/modules/cert-manager/outputs.tf`:

```hcl
###############################################################################
# modules/cert-manager — outputs
###############################################################################

output "namespace" {
  description = "Namespace cert-manager runs in, and the namespace a ClusterIssuer of type `ca` reads its signing secret from."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "release_name" {
  description = "Helm release name. Depend on this from any module that creates a Certificate."
  value       = helm_release.this.name
}

output "rendered_values" {
  description = "The values document handed to Helm. Exposed so tests can assert on image origin without an apply."
  value       = yamlencode(local.values)
}
```

- [ ] **Step 8: Run both tests to verify they pass**

```bash
cd /home/muhammad/devops_practice/devops-project3
./charts/telemetry-certs/test.sh
cd terraform/modules/cert-manager && terraform init -backend=false -input=false && terraform test
```

Expected: `chart ok`, then `Success! 4 passed, 0 failed.`

- [ ] **Step 9: Commit**

```bash
cd /home/muhammad/devops_practice/devops-project3
cd terraform && terraform fmt -recursive && cd ..
git add charts/telemetry-certs terraform/modules/cert-manager
git commit -m "feat(platform): add cert-manager and the pipeline's certificate chain

Cluster A can only verify the gateway if it holds the CA that signed it.
cert-manager issues from a self-signed root here; ACM cannot help,
because a private hosted zone offers no way to prove domain ownership
and ACM Private CA costs more per month than this project's entire
budget.

The issuers and certificates ship as a local chart rather than as
kubernetes_manifest resources: kubernetes_manifest needs the CRD
registered at plan time, so a fresh apply that installs cert-manager and
a Certificate in one run cannot plan at all.

The chart is tested by rendering it and asserting on the output, which
is what catches a bad SAN before cert-manager rejects it at admission."
```

---

### Task 6: The gateway on Cluster B

The far end of the pipeline: an internal NLB, an Alloy deployment that terminates TLS and basic auth on 4317/4318, and the Route 53 record that gives it a name. Until Section 3 lands, it fans out to a debug sink.

**Files:**
- Create: `terraform/modules/telemetry-gateway/versions.tf`
- Create: `terraform/modules/telemetry-gateway/variables.tf`
- Create: `terraform/modules/telemetry-gateway/config.alloy.tftpl`
- Create: `terraform/modules/telemetry-gateway/main.tf`
- Create: `terraform/modules/telemetry-gateway/outputs.tf`
- Test: `terraform/modules/telemetry-gateway/tests/gateway.tftest.hcl`

**Interfaces:**
- Consumes: `charts/telemetry-certs` (Task 5) via `certs_chart_path`; the ECR names from Task 2; `zone_id` from Task 3.
- Produces: outputs `namespace` (string), `ca_certificate_pem` (string), `ingest_username` (string), `ingest_password` (string, sensitive), `gateway_endpoint` (string, `host:4317`), `nlb_hostname` (string), `rendered_config` (string), `rendered_values` (string).

- [ ] **Step 1: Write the failing test**

Create `terraform/modules/telemetry-gateway/tests/gateway.tftest.hcl`:

```hcl
mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  cluster_name      = "obs-platform-prod-observability"
  namespace         = "telemetry"
  gateway_dns_name  = "gateway.observability.internal"
  route53_zone_id   = "Z0123456789ABCDEFGHIJ"
  nlb_subnet_ids    = ["subnet-0aaa", "subnet-0bbb", "subnet-0ccc"]
  nlb_security_group_ids = ["sg-0abcdef0123456789"]
  cert_manager_namespace = "cert-manager"
  certs_chart_path  = "../../../charts/telemetry-certs"
  chart_repository  = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts"
  chart_version     = "1.4.0"
  image_repository  = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/mirror/grafana/alloy"
  image_tag         = "v1.12.0"
}

run "receiver_requires_tls_and_auth_on_both_ports" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "endpoint = \"0.0.0.0:4317\"")
    error_message = "OTLP/gRPC must listen on 4317 — the only port modules/security opens."
  }

  assert {
    condition     = strcontains(output.rendered_config, "endpoint = \"0.0.0.0:4318\"")
    error_message = "OTLP/HTTP must listen on 4318."
  }

  assert {
    condition     = length(regexall("auth += otelcol.auth.basic.ingest.handler", output.rendered_config)) == 2
    error_message = "Both the grpc and http blocks must require auth. Securing only one leaves an unauthenticated ingest path on the other."
  }

  assert {
    condition     = length(regexall("cert_file += \"/etc/alloy/tls/tls.crt\"", output.rendered_config)) == 2
    error_message = "Both listeners must terminate TLS. ADR 0002 puts termination here, not at the NLB."
  }
}

run "credentials_are_never_baked_into_the_config" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "sys.env(\"INGEST_PASSWORD\")")
    error_message = "The password must be read from the environment, not templated into the ConfigMap where kubectl get cm would print it."
  }
}

run "debug_sink_is_the_default_until_lgtm_exists" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "otelcol.exporter.debug")
    error_message = "With lgtm_enabled false the pipeline must still terminate somewhere observable."
  }

  assert {
    condition     = !strcontains(output.rendered_config, "otelcol.exporter.otlphttp")
    error_message = "No LGTM exporter may be rendered while lgtm_enabled is false; it would fail to connect on every batch."
  }
}

run "lgtm_exporters_appear_when_enabled" {
  command = plan

  variables {
    lgtm_enabled   = true
    mimir_endpoint = "http://mimir-nginx.lgtm.svc.cluster.local/otlp"
    loki_endpoint  = "http://loki-gateway.lgtm.svc.cluster.local/otlp"
    tempo_endpoint = "tempo-distributor.lgtm.svc.cluster.local:4317"
  }

  assert {
    condition     = strcontains(output.rendered_config, "mimir-nginx.lgtm.svc.cluster.local")
    error_message = "Metrics must route to Mimir when LGTM is enabled."
  }

  assert {
    condition     = strcontains(output.rendered_config, "loki-gateway.lgtm.svc.cluster.local")
    error_message = "Logs must route to Loki when LGTM is enabled."
  }

  assert {
    condition     = strcontains(output.rendered_config, "tempo-distributor.lgtm.svc.cluster.local:4317")
    error_message = "Traces must route to Tempo over OTLP/gRPC when LGTM is enabled."
  }

  assert {
    condition     = !strcontains(output.rendered_config, "otelcol.exporter.debug")
    error_message = "The debug sink must disappear once real backends exist; leaving it on doubles the gateway's CPU for nothing."
  }
}

run "nlb_is_internal_ip_targeted_and_locked_to_our_security_group" {
  command = plan

  assert {
    condition     = kubernetes_service_v1.gateway.metadata[0].annotations["service.beta.kubernetes.io/aws-load-balancer-scheme"] == "internal"
    error_message = "An internet-facing scheme would put the ingest endpoint on the public internet, which ADR 0002 rejects outright."
  }

  assert {
    condition     = kubernetes_service_v1.gateway.metadata[0].annotations["service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"] == "ip"
    error_message = "ip targets route straight to pod ENIs; instance targets add a hop and need a NodePort."
  }

  assert {
    condition     = kubernetes_service_v1.gateway.metadata[0].annotations["service.beta.kubernetes.io/aws-load-balancer-security-groups"] == "sg-0abcdef0123456789"
    error_message = "The CIDR restriction only has teeth if the group is on the load balancer. Client IP preservation is off by default for ip targets, so a node-only attachment never sees Cluster A's address."
  }

  assert {
    condition     = kubernetes_service_v1.gateway.spec[0].type == "LoadBalancer"
    error_message = "The gateway Service must be of type LoadBalancer."
  }
}

run "dns_record_points_at_the_load_balancer" {
  command = plan

  assert {
    condition     = aws_route53_record.gateway.type == "CNAME"
    error_message = "A CNAME to the NLB's AWS name lets AWS keep resolving it to current private IPs."
  }

  assert {
    condition     = aws_route53_record.gateway.name == "gateway.observability.internal"
    error_message = "The record name must equal the certificate SAN exactly."
  }
}

run "gateway_needs_no_kubernetes_api_access" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_values, "rbac:\n  create: false")
    error_message = "The gateway only receives and forwards. Granting it cluster read access would be privilege it never uses."
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd terraform/modules/telemetry-gateway && terraform init -backend=false -input=false && terraform test
```

Expected: FAIL — no configuration.

- [ ] **Step 3: Write the Alloy config template**

`terraform/modules/telemetry-gateway/config.alloy.tftpl`:

```
// Gateway Alloy — Cluster B.
//
// The single ingest point for cross-cluster telemetry. TLS and authentication
// terminate HERE, not at the NLB, which is a plain TCP passthrough. See
// docs/adr/0002-cross-vpc-telemetry-transport.md.
//
// Rendered by terraform/modules/telemetry-gateway. Do not edit in the cluster.

logging {
  level  = "${log_level}"
  format = "logfmt"
}

// Credentials arrive as environment variables from a Kubernetes Secret, so the
// ConfigMap this file becomes stays safe to read.
otelcol.auth.basic "ingest" {
  username = sys.env("INGEST_USERNAME")
  password = sys.env("INGEST_PASSWORD")
}

otelcol.receiver.otlp "ingest" {
  grpc {
    endpoint = "0.0.0.0:4317"
    auth     = otelcol.auth.basic.ingest.handler

    tls {
      cert_file = "${tls_cert_path}"
      key_file  = "${tls_key_path}"
    }
  }

  http {
    endpoint = "0.0.0.0:4318"
    auth     = otelcol.auth.basic.ingest.handler

    tls {
      cert_file = "${tls_cert_path}"
      key_file  = "${tls_key_path}"
    }
  }

  output {
    metrics = [otelcol.processor.memory_limiter.default.input]
    logs    = [otelcol.processor.memory_limiter.default.input]
    traces  = [otelcol.processor.memory_limiter.default.input]
  }
}

// Sheds load rather than being OOM-killed when a backend stalls. A killed
// gateway drops everything in flight; a limited one refuses new batches and
// lets the agent retry.
otelcol.processor.memory_limiter "default" {
  check_interval = "1s"
  limit          = "${memory_limit}"

  output {
    metrics = [otelcol.processor.batch.default.input]
    logs    = [otelcol.processor.batch.default.input]
    traces  = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.batch "default" {
  send_batch_size     = 8192
  send_batch_max_size = 16384
  timeout             = "2s"

  output {
%{ if lgtm_enabled ~}
    metrics = [otelcol.exporter.otlphttp.mimir.input]
    logs    = [otelcol.exporter.otlphttp.loki.input]
    traces  = [otelcol.exporter.otlp.tempo.input]
%{ else ~}
    metrics = [otelcol.exporter.debug.sink.input]
    logs    = [otelcol.exporter.debug.sink.input]
    traces  = [otelcol.exporter.debug.sink.input]
%{ endif ~}
  }
}

%{ if lgtm_enabled ~}
// Mimir, Loki and Tempo all speak OTLP natively, so the gateway performs no
// format conversion. These are in-cluster, plaintext hops inside Cluster B;
// the trust boundary is the peering link, which is already behind us.
otelcol.exporter.otlphttp "mimir" {
  client {
    endpoint = "${mimir_endpoint}"
    tls {
      insecure = true
    }
  }
}

otelcol.exporter.otlphttp "loki" {
  client {
    endpoint = "${loki_endpoint}"
    tls {
      insecure = true
    }
  }
}

otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "${tempo_endpoint}"
    tls {
      insecure = true
    }
  }
}
%{ else ~}
// No LGTM stack yet. The debug sink makes arrival observable in pod logs,
// which is this pipeline's definition of done until Section 3 lands.
otelcol.exporter.debug "sink" {
  verbosity = "basic"
}
%{ endif ~}
```

- [ ] **Step 4: Write the variables**

`terraform/modules/telemetry-gateway/variables.tf`:

```hcl
###############################################################################
# modules/telemetry-gateway — input variables
###############################################################################

variable "cluster_name" {
  description = "Name of Cluster B. Used for resource naming and tags only."
  type        = string
}

variable "namespace" {
  description = "Namespace the gateway runs in. Created by this module."
  type        = string
  default     = "telemetry"
}

variable "gateway_dns_name" {
  description = <<-EOT
    Fully qualified name Cluster A connects to. Must match the certificate SAN
    exactly — a mismatch fails the TLS handshake after the TCP connection has
    already succeeded, which reads like a network fault and is not one.
  EOT
  type        = string
}

variable "route53_zone_id" {
  description = "Private hosted zone the gateway record is created in."
  type        = string
}

variable "cert_manager_namespace" {
  description = "Namespace cert-manager runs in, where the CA secret is read from."
  type        = string
  default     = "cert-manager"
}

variable "certs_chart_path" {
  description = "Filesystem path to charts/telemetry-certs, relative to this module."
  type        = string
  default     = "../../../charts/telemetry-certs"
}

# --- Load balancer -------------------------------------------------------------

variable "nlb_subnet_ids" {
  description = "Private subnets in the observability VPC the internal NLB places its ENIs in."
  type        = list(string)
}

variable "nlb_security_group_ids" {
  description = <<-EOT
    Security groups attached to the NLB itself. Pass the otlp_ingress group from
    modules/security. This is where the workload-VPC CIDR restriction actually
    takes effect: client IP preservation is off by default for NLB ip targets,
    so a group attached only to the nodes never observes Cluster A's address.
  EOT
  type        = list(string)
}

# --- Chart and image -----------------------------------------------------------

variable "chart_repository" {
  description = "OCI registry holding the mirrored Alloy chart."
  type        = string
}

variable "chart_version" {
  description = "Exact Alloy chart version, matching ALLOY_CHART_VERSION in scripts/mirror-images.sh."
  type        = string
}

variable "image_repository" {
  description = "ECR repository holding the mirrored Alloy image."
  type        = string
}

variable "image_tag" {
  description = "Exact Alloy image tag, matching ALLOY_IMAGE_TAG in scripts/mirror-images.sh."
  type        = string
}

variable "replicas" {
  description = "Gateway replicas. Two spreads ingest across AZs and survives a node roll."
  type        = number
  default     = 2
}

# --- Pipeline ------------------------------------------------------------------

variable "lgtm_enabled" {
  description = <<-EOT
    Render the Mimir, Loki and Tempo exporters. Leave false until the LGTM
    stack exists in Cluster B; a rendered exporter with no backend fails on
    every batch and buries the real signal in retry noise.
  EOT
  type        = bool
  default     = false
}

variable "mimir_endpoint" {
  description = "Mimir OTLP endpoint inside Cluster B. Only used when lgtm_enabled is true."
  type        = string
  default     = "http://mimir-nginx.lgtm.svc.cluster.local/otlp"
}

variable "loki_endpoint" {
  description = "Loki OTLP endpoint inside Cluster B. Only used when lgtm_enabled is true."
  type        = string
  default     = "http://loki-gateway.lgtm.svc.cluster.local/otlp"
}

variable "tempo_endpoint" {
  description = "Tempo OTLP/gRPC endpoint inside Cluster B, host:port. Only used when lgtm_enabled is true."
  type        = string
  default     = "tempo-distributor.lgtm.svc.cluster.local:4317"
}

variable "log_level" {
  description = "Alloy's own log level."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be one of debug, info, warn, error."
  }
}

variable "memory_limit" {
  description = "Soft memory ceiling for the memory_limiter processor. Keep below the container memory limit."
  type        = string
  default     = "512MiB"
}

variable "cert_wait_duration" {
  description = "How long to wait after the certificate chart before reading the CA secret. cert-manager issues in seconds; this is slack, not a timeout."
  type        = string
  default     = "60s"
}

variable "tags" {
  description = "Tags merged onto every AWS resource in this module."
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 5: Write the implementation**

`terraform/modules/telemetry-gateway/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
```

`terraform/modules/telemetry-gateway/main.tf`:

```hcl
###############################################################################
# modules/telemetry-gateway — Cluster B
#
# The far end of the cross-cluster pipeline. An internal NLB accepts 4317/4318
# from the workload VPC and passes TCP straight through to Alloy, which
# terminates TLS and basic auth and fans out locally.
#
#   docs/adr/0002-cross-vpc-telemetry-transport.md   why peering, and the
#                                                    three-layer security model
#   docs/adr/0007-cross-cluster-name-resolution.md   why an NLB plus a private
#                                                    zone, and not CoreDNS
###############################################################################

locals {
  tags = merge(
    var.tags,
    {
      "Module"    = "telemetry-gateway"
      "ManagedBy" = "terraform"
    },
  )

  release_name       = "alloy-gateway"
  credentials_secret = "telemetry-ingest-credentials"
  tls_secret         = "telemetry-gateway-tls"
  ca_secret          = "telemetry-ca-key-pair"
  ingest_username    = "alloy-workload"

  tls_mount_path = "/etc/alloy/tls"

  # Selector labels the Alloy chart puts on its pods. The NLB Service below
  # targets these directly rather than going through the chart's own Service,
  # so every load balancer annotation stays visible in this file.
  pod_selector = {
    "app.kubernetes.io/name"     = "alloy"
    "app.kubernetes.io/instance" = local.release_name
  }

  config = templatefile("${path.module}/config.alloy.tftpl", {
    log_level      = var.log_level
    memory_limit   = var.memory_limit
    tls_cert_path  = "${local.tls_mount_path}/tls.crt"
    tls_key_path   = "${local.tls_mount_path}/tls.key"
    lgtm_enabled   = var.lgtm_enabled
    mimir_endpoint = var.mimir_endpoint
    loki_endpoint  = var.loki_endpoint
    tempo_endpoint = var.tempo_endpoint
  })

  values = {
    alloy = {
      configMap = {
        create  = true
        content = local.config
      }

      extraEnv = [
        {
          name = "INGEST_USERNAME"
          valueFrom = {
            secretKeyRef = { name = local.credentials_secret, key = "username" }
          }
        },
        {
          name = "INGEST_PASSWORD"
          valueFrom = {
            secretKeyRef = { name = local.credentials_secret, key = "password" }
          }
        },
      ]

      mounts = {
        extra = [
          { name = "tls", mountPath = local.tls_mount_path, readOnly = true },
        ]
      }

      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
    }

    controller = {
      type     = "deployment"
      replicas = var.replicas

      volumes = {
        extra = [
          { name = "tls", secret = { secretName = local.tls_secret } },
        ]
      }
    }

    # The gateway receives and forwards. It never reads the Kubernetes API, so
    # it gets no access to it.
    rbac = {
      create = false
    }

    # Our own Service below carries the load balancer annotations.
    service = {
      enabled = false
    }

    image = {
      registry   = ""
      repository = var.image_repository
      tag        = var.image_tag
    }
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "telemetry-pipeline"
    }
  }
}

###############################################################################
# Ingest credential
#
# Generated here, never committed. It does land in Terraform state, which is
# S3-encrypted per ADR 0003. Changing the keeper rotates it on both clusters in
# a single apply.
###############################################################################

resource "random_password" "ingest" {
  length  = 40
  special = false # keeps it safe in a URL, a header and a shell without quoting

  keepers = {
    cluster = var.cluster_name
  }
}

resource "kubernetes_secret_v1" "credentials" {
  metadata {
    name      = local.credentials_secret
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    username = local.ingest_username
    password = random_password.ingest.result
  }

  type = "Opaque"
}

###############################################################################
# Certificates
###############################################################################

resource "helm_release" "certs" {
  name             = "telemetry-certs"
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  chart            = var.certs_chart_path
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 300

  values = [yamlencode({
    certManagerNamespace = var.cert_manager_namespace
    gatewayNamespace     = kubernetes_namespace_v1.this.metadata[0].name
    gatewayDnsName       = var.gateway_dns_name
    caSecretName         = local.ca_secret
    gatewaySecretName    = local.tls_secret
  })]
}

# helm_release.wait returns when the custom resources are accepted, not when
# cert-manager has finished issuing. Reading the CA secret immediately after is
# a race; this is the slack that avoids it.
resource "time_sleep" "wait_for_issuance" {
  depends_on      = [helm_release.certs]
  create_duration = var.cert_wait_duration
}

data "kubernetes_secret_v1" "ca" {
  depends_on = [time_sleep.wait_for_issuance]

  metadata {
    name      = local.ca_secret
    namespace = var.cert_manager_namespace
  }
}

###############################################################################
# Gateway
###############################################################################

resource "helm_release" "gateway" {
  name             = local.release_name
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  repository       = var.chart_repository
  chart            = "alloy"
  version          = var.chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [yamlencode(local.values)]

  depends_on = [
    kubernetes_secret_v1.credentials,
    time_sleep.wait_for_issuance,
  ]
}

###############################################################################
# Internal NLB
#
# Built here rather than through the chart's own Service so that every
# annotation that matters to the security model is visible in one place.
###############################################################################

resource "kubernetes_service_v1" "gateway" {
  metadata {
    name      = "telemetry-gateway"
    namespace = kubernetes_namespace_v1.this.metadata[0].name

    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internal"
      "service.beta.kubernetes.io/aws-load-balancer-subnets"         = join(",", var.nlb_subnet_ids)
      "service.beta.kubernetes.io/aws-load-balancer-security-groups" = join(",", var.nlb_security_group_ids)

      # Let the controller open the node-side rules from the load balancer's
      # group, so pod traffic is admitted without widening anything by hand.
      "service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules" = "true"

      # TCP, not TLS: termination belongs at the pod, per ADR 0002.
      "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "tcp"
    }
  }

  spec {
    type     = "LoadBalancer"
    selector = local.pod_selector

    port {
      name        = "otlp-grpc"
      port        = 4317
      target_port = 4317
      protocol    = "TCP"
    }

    port {
      name        = "otlp-http"
      port        = 4318
      target_port = 4318
      protocol    = "TCP"
    }
  }

  # The controller has to be running to reconcile this into an NLB, and the
  # pods have to exist for the target group to have anything in it.
  depends_on = [helm_release.gateway]

  timeouts {
    create = "15m"
  }
}

###############################################################################
# The name
#
# A CNAME rather than an alias: the NLB is created by Kubernetes, so its zone
# ID is not a Terraform-known value here, and AWS keeps its own name resolving
# to current private addresses regardless.
###############################################################################

resource "aws_route53_record" "gateway" {
  zone_id = var.route53_zone_id
  name    = var.gateway_dns_name
  type    = "CNAME"
  ttl     = 60
  records = [kubernetes_service_v1.gateway.status[0].load_balancer[0].ingress[0].hostname]
}
```

`terraform/modules/telemetry-gateway/outputs.tf`:

```hcl
###############################################################################
# modules/telemetry-gateway — outputs
#
# This is the contract the agent side consumes. Everything Cluster A needs to
# know about Cluster B is here: a name, a CA, and a credential.
###############################################################################

output "namespace" {
  description = "Namespace the gateway runs in."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "gateway_endpoint" {
  description = "host:port the agent exports to."
  value       = "${var.gateway_dns_name}:4317"
}

output "gateway_dns_name" {
  description = "Fully qualified name of the gateway, matching the certificate SAN."
  value       = var.gateway_dns_name
}

output "nlb_hostname" {
  description = "AWS-generated name of the internal NLB. Useful when diagnosing whether a resolution failure is Route 53 or the load balancer."
  value       = kubernetes_service_v1.gateway.status[0].load_balancer[0].ingress[0].hostname
}

output "ca_certificate_pem" {
  description = "PEM of the CA that signed the gateway certificate. Feed to the agent so it can verify for real. Public material, deliberately not sensitive."
  value       = lookup(data.kubernetes_secret_v1.ca.data, "ca.crt", "")
}

output "ingest_username" {
  description = "Username the agent authenticates with."
  value       = local.ingest_username
}

output "ingest_password" {
  description = "Password the agent authenticates with."
  value       = random_password.ingest.result
  sensitive   = true
}

output "rendered_config" {
  description = "The rendered .alloy config. Exposed so tests can assert on TLS, auth and exporter routing without an apply."
  value       = local.config
}

output "rendered_values" {
  description = "The values document handed to Helm."
  value       = yamlencode(local.values)
}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd terraform/modules/telemetry-gateway && terraform init -backend=false -input=false && terraform test
```

Expected: PASS, `Success! 7 passed, 0 failed.`

- [ ] **Step 7: Commit**

```bash
cd /home/muhammad/devops_practice/devops-project3
cd terraform && terraform fmt -recursive && cd ..
git add terraform/modules/telemetry-gateway
git commit -m "feat(terraform): add the telemetry gateway on Cluster B

The far end of the pipeline. An internal NLB accepts 4317 and 4318 from
the workload VPC and passes TCP straight through; Alloy terminates TLS
and basic auth and fans out locally. That split is what ADR 0002
specified, and it keeps the peering link at exactly two ports.

The NLB Service is built here rather than through the chart so that
every annotation the security model depends on is readable in one file.
The security group goes on the load balancer, not only on the nodes:
client IP preservation is off by default for ip targets, so a node-only
attachment never observes Cluster A's address and the CIDR restriction
would quietly do nothing.

The record is a CNAME rather than an alias because the NLB is created by
Kubernetes, so its hosted zone ID is not a value Terraform knows here.

With no LGTM stack yet, the exporters are a debug sink. Enabling them is
one variable."
```

---

### Task 7: The Alloy DaemonSet on Cluster A

Three collection paths — OTLP from the instrumented workloads, Prometheus scrapes of kubelet and cAdvisor, and pod log tails — converted to OTLP in-process and leaving on one authenticated connection.

**Files:**
- Create: `terraform/modules/telemetry-agent/versions.tf`
- Create: `terraform/modules/telemetry-agent/variables.tf`
- Create: `terraform/modules/telemetry-agent/config.alloy.tftpl`
- Create: `terraform/modules/telemetry-agent/main.tf`
- Create: `terraform/modules/telemetry-agent/outputs.tf`
- Test: `terraform/modules/telemetry-agent/tests/agent.tftest.hcl`

**Interfaces:**
- Consumes: `modules/telemetry-gateway` outputs `gateway_endpoint`, `ca_certificate_pem`, `ingest_username`, `ingest_password` — wired by the root module in Task 8, never by this module directly.
- Produces: outputs `namespace` (string), `rendered_config` (string), `rendered_values` (string).

- [ ] **Step 1: Write the failing test**

Create `terraform/modules/telemetry-agent/tests/agent.tftest.hcl`:

```hcl
mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  cluster_name       = "obs-platform-prod-workload"
  namespace          = "telemetry"
  gateway_endpoint   = "gateway.observability.internal:4317"
  gateway_ca_pem     = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
  ingest_username    = "alloy-workload"
  ingest_password    = "not-a-real-password"
  chart_repository   = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts"
  chart_version      = "1.4.0"
  image_repository   = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/mirror/grafana/alloy"
  image_tag          = "v1.12.0"
}

run "exports_everything_to_the_gateway_and_nowhere_else" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "endpoint = \"gateway.observability.internal:4317\"")
    error_message = "All three signals leave on one connection to the gateway."
  }

  assert {
    condition     = length(regexall("otelcol\\.exporter\\.", output.rendered_config)) == 1
    error_message = "Exactly one exporter. ADR 0002 forbids Cluster A talking to Loki, Mimir or Tempo directly, and only 4317/4318 cross the peering link."
  }

  assert {
    condition     = !strcontains(output.rendered_config, "3100")
    error_message = "No direct Loki push port may appear; it is not open on the peering link."
  }
}

run "gateway_certificate_is_actually_verified" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "ca_file = \"/etc/alloy/certs/ca.crt\"")
    error_message = "The exporter must verify against the CA copied from Cluster B."
  }

  assert {
    condition     = !strcontains(output.rendered_config, "insecure = true")
    error_message = "The gateway connection must never disable TLS."
  }

  assert {
    condition     = length(regexall("insecure_skip_verify = true", output.rendered_config)) == 1
    error_message = "Exactly one skip is legitimate: the kubelet, whose serving certificate is signed by a per-node CA the ServiceAccount bundle does not cover. A second occurrence means the gateway hop stopped verifying."
  }
}

run "credentials_come_from_the_environment" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "sys.env(\"INGEST_PASSWORD\")")
    error_message = "The password must not be templated into the ConfigMap."
  }

  assert {
    condition     = !strcontains(output.rendered_config, "not-a-real-password")
    error_message = "The literal password must never appear in the rendered config."
  }
}

run "discovery_is_scoped_to_the_local_node" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "spec.nodeName=")
    error_message = "Pod discovery must be node-scoped. Without it every DaemonSet instance lists every pod in the cluster and the API server pays for it once per node."
  }

  assert {
    condition     = strcontains(output.rendered_config, "sys.env(\"NODE_NAME\")")
    error_message = "The node name comes from the downward API, not from HOSTNAME — HOSTNAME in a pod is the pod's name."
  }

  assert {
    condition     = strcontains(output.rendered_values, "fieldPath: spec.nodeName")
    error_message = "NODE_NAME must be injected from the downward API in the chart values."
  }
}

run "all_three_signals_are_collected" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_config, "otelcol.receiver.otlp")
    error_message = "Traces and app metrics arrive over OTLP from the instrumented workloads."
  }

  assert {
    condition     = strcontains(output.rendered_config, "otelcol.receiver.prometheus")
    error_message = "Infrastructure metrics are scraped as Prometheus and bridged into OTLP."
  }

  assert {
    condition     = strcontains(output.rendered_config, "otelcol.receiver.loki")
    error_message = "Pod logs are tailed as Loki streams and bridged into OTLP."
  }

  assert {
    condition     = strcontains(output.rendered_config, "/metrics/cadvisor")
    error_message = "cAdvisor is a separate scrape path from the kubelet's own metrics; missing it loses all container CPU and memory."
  }
}

run "telemetry_is_stamped_with_its_origin_cluster" {
  command = plan

  assert {
    condition     = length(regexall("obs-platform-prod-workload", output.rendered_config)) >= 3
    error_message = "Every signal must carry its origin cluster, or Grafana cannot show that data came from Cluster A — which is the Proof of Life requirement."
  }
}

run "runs_as_a_daemonset_with_host_logs_mounted" {
  command = plan

  assert {
    condition     = strcontains(output.rendered_values, "type: daemonset")
    error_message = "Node-level logs and kubelet metrics require one instance per node."
  }

  assert {
    condition     = strcontains(output.rendered_values, "varlog: true")
    error_message = "Tailing /var/log/pods requires the host mount."
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd terraform/modules/telemetry-agent && terraform init -backend=false -input=false && terraform test
```

Expected: FAIL — no configuration.

- [ ] **Step 3: Write the Alloy config template**

`terraform/modules/telemetry-agent/config.alloy.tftpl`:

```
// Agent Alloy — Cluster A.
//
// Collects all three signals and converts them to OTLP in-process, so
// everything leaves this cluster on ONE authenticated connection to the
// gateway. ADR 0002 opens exactly two ports across the peering link; nothing
// here may talk to Loki, Mimir or Tempo directly.
//
// Rendered by terraform/modules/telemetry-agent. Do not edit in the cluster.

logging {
  level  = "${log_level}"
  format = "logfmt"
}

// ---------------------------------------------------------------------------
// 1. Traces and application metrics from the instrumented workloads.
//    Cluster-local and plaintext: the peering link is the trust boundary, not
//    the pod network inside a single cluster.
// ---------------------------------------------------------------------------

otelcol.receiver.otlp "apps" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }

  http {
    endpoint = "0.0.0.0:4318"
  }

  output {
    metrics = [otelcol.processor.k8sattributes.apps.input]
    logs    = [otelcol.processor.k8sattributes.apps.input]
    traces  = [otelcol.processor.k8sattributes.apps.input]
  }
}

// Enriches whatever the application sent with the pod, namespace and workload
// it came from, so a span can be traced back to a Deployment without the
// application having to know its own coordinates.
otelcol.processor.k8sattributes "apps" {
  extract {
    metadata = [
      "k8s.namespace.name",
      "k8s.pod.name",
      "k8s.pod.uid",
      "k8s.deployment.name",
      "k8s.node.name",
      "k8s.container.name",
    ]
  }

  pod_association {
    source {
      from = "resource_attribute"
      name = "k8s.pod.ip"
    }
  }

  pod_association {
    source {
      from = "connection"
    }
  }

  output {
    metrics = [otelcol.processor.transform.stamp.input]
    logs    = [otelcol.processor.transform.stamp.input]
    traces  = [otelcol.processor.transform.stamp.input]
  }
}

// ---------------------------------------------------------------------------
// 2. Infrastructure metrics — the kubelet and cAdvisor on THIS node only.
// ---------------------------------------------------------------------------

discovery.kubernetes "local_node" {
  role = "node"

  selectors {
    role  = "node"
    field = "metadata.name=" + sys.env("NODE_NAME")
  }
}

discovery.relabel "kubelet" {
  targets = discovery.kubernetes.local_node.targets

  rule {
    source_labels = ["__meta_kubernetes_node_address_InternalIP"]
    action        = "replace"
    target_label  = "__address__"
    replacement   = "$1:10250"
  }

  rule {
    source_labels = ["__meta_kubernetes_node_name"]
    action        = "replace"
    target_label  = "node"
  }
}

// The kubelet's own metrics: pod lifecycle, volume stats, runtime health.
prometheus.scrape "kubelet" {
  targets         = discovery.relabel.kubelet.output
  scheme          = "https"
  metrics_path    = "/metrics"
  scrape_interval = "${scrape_interval}"

  bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"

  tls_config {
    // The kubelet serves a certificate signed by a per-node CA that the
    // ServiceAccount bundle does not contain. This is a hop to the node's own
    // address on its own network and is unrelated to the cross-cluster
    // connection, which verifies its CA properly.
    insecure_skip_verify = true
  }

  forward_to = [prometheus.relabel.infra.receiver]
}

// cAdvisor: per-container CPU, memory, network and filesystem. A separate
// path on the same endpoint — omitting it loses all container-level usage.
prometheus.scrape "cadvisor" {
  targets         = discovery.relabel.kubelet.output
  scheme          = "https"
  metrics_path    = "/metrics/cadvisor"
  scrape_interval = "${scrape_interval}"

  bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"

  tls_config {
    insecure_skip_verify = true
  }

  forward_to = [prometheus.relabel.infra.receiver]
}

prometheus.relabel "infra" {
  rule {
    action       = "replace"
    target_label = "cluster"
    replacement  = "${cluster_name}"
  }

  forward_to = [otelcol.receiver.prometheus.infra.receiver]
}

// Bridges the Prometheus ecosystem into OTLP so infrastructure metrics leave
// on the same connection as everything else.
otelcol.receiver.prometheus "infra" {
  output {
    metrics = [otelcol.processor.transform.stamp.input]
  }
}

// ---------------------------------------------------------------------------
// 3. Pod logs from THIS node.
// ---------------------------------------------------------------------------

discovery.kubernetes "local_pods" {
  role = "pod"

  selectors {
    role  = "pod"
    field = "spec.nodeName=" + sys.env("NODE_NAME")
  }
}

discovery.relabel "pod_logs" {
  targets = discovery.kubernetes.local_pods.targets

  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    action        = "replace"
    target_label  = "namespace"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    action        = "replace"
    target_label  = "pod"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    action        = "replace"
    target_label  = "container"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    action        = "replace"
    target_label  = "app"
  }

  rule {
    source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_container_name"]
    action        = "replace"
    target_label  = "job"
    separator     = "/"
    replacement   = "$1"
  }

  // The container runtime writes to a path keyed by pod UID and container
  // name. This is what turns a discovered pod into a file to tail.
  rule {
    source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
    action        = "replace"
    target_label  = "__path__"
    separator     = "/"
    replacement   = "/var/log/pods/*$1/*.log"
  }
}

local.file_match "pod_logs" {
  path_targets = discovery.relabel.pod_logs.output
}

loki.source.file "pod_logs" {
  targets    = local.file_match.pod_logs.targets
  forward_to = [loki.process.pod_logs.receiver]
}

loki.process "pod_logs" {
  // Container logs are CRI-formatted: timestamp, stream, tag, then the line.
  // Without this the whole envelope becomes the log body.
  stage.cri {}

  stage.static_labels {
    values = {
      cluster = "${cluster_name}",
    }
  }

  forward_to = [otelcol.receiver.loki.pod_logs.receiver]
}

// Bridges Loki streams into OTLP.
otelcol.receiver.loki "pod_logs" {
  output {
    logs = [otelcol.processor.transform.stamp.input]
  }
}

// ---------------------------------------------------------------------------
// 4. Common tail — stamp, limit, batch, export.
// ---------------------------------------------------------------------------

// Stamps the origin cluster as a RESOURCE attribute on every signal. This is
// what lets a Grafana panel in Cluster B prove that a span or a sample came
// from Cluster A, which is the project's Proof of Life requirement.
otelcol.processor.transform "stamp" {
  error_mode = "ignore"

  trace_statements {
    context    = "resource"
    statements = ["set(attributes[\"cluster\"], \"${cluster_name}\")"]
  }

  metric_statements {
    context    = "resource"
    statements = ["set(attributes[\"cluster\"], \"${cluster_name}\")"]
  }

  log_statements {
    context    = "resource"
    statements = ["set(attributes[\"cluster\"], \"${cluster_name}\")"]
  }

  output {
    metrics = [otelcol.processor.memory_limiter.default.input]
    logs    = [otelcol.processor.memory_limiter.default.input]
    traces  = [otelcol.processor.memory_limiter.default.input]
  }
}

// A gateway outage must shed load, not OOM-kill the DaemonSet. A killed agent
// takes its file-tail offsets with it and re-reads on restart.
otelcol.processor.memory_limiter "default" {
  check_interval = "1s"
  limit          = "${memory_limit}"

  output {
    metrics = [otelcol.processor.batch.default.input]
    logs    = [otelcol.processor.batch.default.input]
    traces  = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.batch "default" {
  send_batch_size     = 8192
  send_batch_max_size = 16384
  timeout             = "5s"

  output {
    metrics = [otelcol.exporter.otlp.gateway.input]
    logs    = [otelcol.exporter.otlp.gateway.input]
    traces  = [otelcol.exporter.otlp.gateway.input]
  }
}

otelcol.auth.basic "gateway" {
  username = sys.env("INGEST_USERNAME")
  password = sys.env("INGEST_PASSWORD")
}

// The one hop that leaves this cluster. Verified against the CA that Terraform
// copied out of Cluster B, so verification is real rather than skipped.
otelcol.exporter.otlp "gateway" {
  client {
    endpoint = "${gateway_endpoint}"
    auth     = otelcol.auth.basic.gateway.handler

    tls {
      ca_file = "${ca_file_path}"
    }
  }

  retry_on_failure {
    enabled          = true
    initial_interval = "5s"
    max_interval     = "30s"
    max_elapsed_time = "5m"
  }
}
```

- [ ] **Step 4: Write the variables**

`terraform/modules/telemetry-agent/variables.tf`:

```hcl
###############################################################################
# modules/telemetry-agent — input variables
#
# This module knows nothing about Cluster B beyond a hostname, a CA and a
# credential. All three are inputs, wired by the root module.
###############################################################################

variable "cluster_name" {
  description = "Name of Cluster A. Stamped onto every signal as the `cluster` resource attribute, which is how Grafana tells the two clusters apart."
  type        = string
}

variable "namespace" {
  description = "Namespace the agent runs in. Created by this module."
  type        = string
  default     = "telemetry"
}

variable "gateway_endpoint" {
  description = "host:port of the gateway in Cluster B. Must be the name the gateway certificate is issued for."
  type        = string
}

variable "gateway_ca_pem" {
  description = "PEM of the CA that signed the gateway certificate. Public material; comes from the gateway module's ca_certificate_pem output."
  type        = string

  validation {
    condition     = can(regex("BEGIN CERTIFICATE", var.gateway_ca_pem))
    error_message = "gateway_ca_pem must be a PEM certificate. An empty value usually means the CA secret was read before cert-manager had issued it."
  }
}

variable "ingest_username" {
  description = "Username the agent authenticates to the gateway with."
  type        = string
}

variable "ingest_password" {
  description = "Password the agent authenticates to the gateway with."
  type        = string
  sensitive   = true
}

variable "chart_repository" {
  description = "OCI registry holding the mirrored Alloy chart."
  type        = string
}

variable "chart_version" {
  description = "Exact Alloy chart version, matching ALLOY_CHART_VERSION in scripts/mirror-images.sh."
  type        = string
}

variable "image_repository" {
  description = "ECR repository holding the mirrored Alloy image."
  type        = string
}

variable "image_tag" {
  description = "Exact Alloy image tag, matching ALLOY_IMAGE_TAG in scripts/mirror-images.sh."
  type        = string
}

variable "scrape_interval" {
  description = "How often kubelet and cAdvisor are scraped. 60s keeps cardinality and cost down for a lab; 15s is the production reflex."
  type        = string
  default     = "60s"
}

variable "log_level" {
  description = "Alloy's own log level."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be one of debug, info, warn, error."
  }
}

variable "memory_limit" {
  description = "Soft memory ceiling for the memory_limiter processor. Keep below the container memory limit."
  type        = string
  default     = "384MiB"
}
```

- [ ] **Step 5: Write the implementation**

`terraform/modules/telemetry-agent/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }
}
```

`terraform/modules/telemetry-agent/main.tf`:

```hcl
###############################################################################
# modules/telemetry-agent — Cluster A
#
# One Alloy per node. Collects OTLP from the instrumented workloads, scrapes
# the local kubelet and cAdvisor, tails this node's pod logs, converts all
# three to OTLP, and ships them on a single authenticated connection to the
# gateway in Cluster B.
#
#   docs/adr/0006-telemetry-agent-selection.md   why Alloy, not the upstream
#                                                collector plus two more agents
#   docs/adr/0002-cross-vpc-telemetry-transport.md
###############################################################################

locals {
  release_name       = "alloy-agent"
  credentials_secret = "telemetry-gateway-credentials"
  ca_secret          = "telemetry-gateway-ca"
  ca_mount_path      = "/etc/alloy/certs"

  config = templatefile("${path.module}/config.alloy.tftpl", {
    cluster_name     = var.cluster_name
    log_level        = var.log_level
    memory_limit     = var.memory_limit
    scrape_interval  = var.scrape_interval
    gateway_endpoint = var.gateway_endpoint
    ca_file_path     = "${local.ca_mount_path}/ca.crt"
  })

  values = {
    alloy = {
      configMap = {
        create  = true
        content = local.config
      }

      extraEnv = [
        {
          # HOSTNAME inside a pod is the POD's name. Node-scoped discovery
          # needs the node's name, which only the downward API can supply.
          name = "NODE_NAME"
          valueFrom = {
            fieldRef = { fieldPath = "spec.nodeName" }
          }
        },
        {
          name = "INGEST_USERNAME"
          valueFrom = {
            secretKeyRef = { name = local.credentials_secret, key = "username" }
          }
        },
        {
          name = "INGEST_PASSWORD"
          valueFrom = {
            secretKeyRef = { name = local.credentials_secret, key = "password" }
          }
        },
      ]

      mounts = {
        # Tailing /var/log/pods needs the host's log directory.
        varlog = true

        extra = [
          { name = "gateway-ca", mountPath = local.ca_mount_path, readOnly = true },
        ]
      }

      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }

    controller = {
      # One per node: node-level logs and kubelet metrics cannot be collected
      # any other way.
      type = "daemonset"

      volumes = {
        extra = [
          { name = "gateway-ca", secret = { secretName = local.ca_secret } },
        ]
      }

      # Telemetry collection must survive on nodes that are cordoned or
      # carrying a taint, or the record of what went wrong there is lost.
      tolerations = [
        { operator = "Exists" },
      ]
    }

    # Read-only discovery of pods, nodes and namespaces, and access to the
    # kubelet metrics endpoints. Nothing writable.
    rbac = {
      create = true
    }

    image = {
      registry   = ""
      repository = var.image_repository
      tag        = var.image_tag
    }
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "telemetry-pipeline"
    }
  }
}

# The credential the gateway will check. Generated in the gateway module and
# handed here, so there is exactly one source of truth for it.
resource "kubernetes_secret_v1" "credentials" {
  metadata {
    name      = local.credentials_secret
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    username = var.ingest_username
    password = var.ingest_password
  }

  type = "Opaque"
}

# The CA that signed the gateway's certificate. Public material, which is why
# it travels as a plain Secret rather than through a secret store.
resource "kubernetes_secret_v1" "gateway_ca" {
  metadata {
    name      = local.ca_secret
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    "ca.crt" = var.gateway_ca_pem
  }

  type = "Opaque"
}

resource "helm_release" "this" {
  name             = local.release_name
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  repository       = var.chart_repository
  chart            = "alloy"
  version          = var.chart_version
  create_namespace = false

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [yamlencode(local.values)]

  depends_on = [
    kubernetes_secret_v1.credentials,
    kubernetes_secret_v1.gateway_ca,
  ]
}
```

`terraform/modules/telemetry-agent/outputs.tf`:

```hcl
###############################################################################
# modules/telemetry-agent — outputs
###############################################################################

output "namespace" {
  description = "Namespace the agent runs in."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "otlp_endpoint" {
  description = "In-cluster OTLP/gRPC endpoint the instrumented workloads should send to. Point the Boutique's OTEL_EXPORTER_OTLP_ENDPOINT at this."
  value       = "http://${local.release_name}.${kubernetes_namespace_v1.this.metadata[0].name}.svc.cluster.local:4317"
}

output "rendered_config" {
  description = "The rendered .alloy config. Exposed so tests can assert on routing, verification and node scoping without an apply."
  value       = local.config
}

output "rendered_values" {
  description = "The values document handed to Helm."
  value       = yamlencode(local.values)
}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd terraform/modules/telemetry-agent && terraform init -backend=false -input=false && terraform test
```

Expected: PASS, `Success! 7 passed, 0 failed.`

- [ ] **Step 7: Run the whole module suite**

```bash
cd terraform && make test
```

Expected: every module reports `Success!` — irsa, dns-private-zone, aws-lb-controller, cert-manager, telemetry-gateway, telemetry-agent.

- [ ] **Step 8: Commit**

```bash
cd /home/muhammad/devops_practice/devops-project3
cd terraform && terraform fmt -recursive && cd ..
git add terraform/modules/telemetry-agent
git commit -m "feat(terraform): add the Alloy DaemonSet on Cluster A

Three collection paths converge on one exporter. OTLP from the
instrumented workloads, Prometheus scrapes of the local kubelet and
cAdvisor, and this node's pod logs are all converted to OTLP in-process,
so everything leaves the cluster on a single authenticated connection.
That is what keeps the peering link at the two ports ADR 0002 opens.

Discovery is scoped to the local node through the downward API rather
than HOSTNAME, which inside a pod is the pod's own name. Unscoped, every
instance of the DaemonSet lists every pod in the cluster and the API
server pays for it once per node.

One insecure_skip_verify remains, on the kubelet scrape, whose serving
certificate is signed by a per-node CA the ServiceAccount bundle does
not carry. A test asserts there is exactly one, so the cross-cluster hop
cannot quietly stop verifying.

Every signal is stamped with its origin cluster as a resource attribute.
Without it there is no way to show in Grafana that data came from
Cluster A, which is the project's Proof of Life requirement."
```

---

### Task 8: The platform root module

Where the two sides meet. Four aliased providers, one per (tool, cluster) pair, configured from the infrastructure state that `envs/prod` already publishes.

**Files:**
- Create: `terraform/envs/prod-platform/versions.tf`
- Create: `terraform/envs/prod-platform/backend.tf`
- Create: `terraform/envs/prod-platform/backend.hcl.example`
- Create: `terraform/envs/prod-platform/variables.tf`
- Create: `terraform/envs/prod-platform/data.tf`
- Create: `terraform/envs/prod-platform/locals.tf`
- Create: `terraform/envs/prod-platform/providers.tf`
- Create: `terraform/envs/prod-platform/main.tf`
- Create: `terraform/envs/prod-platform/outputs.tf`
- Create: `terraform/envs/prod-platform/terraform.tfvars.example`
- Modify: `terraform/Makefile`

**Interfaces:**
- Consumes: every module from Tasks 1–7, and `envs/prod`'s `platform`, `observability_private_subnet_ids` and `otlp_security_group_ids` outputs. `envs/prod` itself is **not modified** — the cluster CA data and OIDC issuer host come from `data "aws_eks_cluster"` lookups by name.
- Produces: outputs `gateway_endpoint`, `gateway_dns_name`, `nlb_hostname`, `agent_otlp_endpoint`, `private_zone_id`, `verification` (a map of ready-to-run check commands).

- [ ] **Step 1: Write versions, backend and variables**

`terraform/envs/prod-platform/versions.tf`:

```hcl
###############################################################################
# envs/prod-platform — provider and Terraform version constraints
###############################################################################

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
```

`terraform/envs/prod-platform/backend.tf`:

```hcl
###############################################################################
# envs/prod-platform — remote state
#
# Same bucket as envs/prod, different key. Two states, so a failed Helm release
# can never leave the infrastructure state in a partial condition.
#   docs/adr/0003-s3-native-state-locking.md
#   docs/adr/0008-two-stage-terraform.md
###############################################################################

terraform {
  backend "s3" {
    key          = "prod/kubernetes-platform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
```

`terraform/envs/prod-platform/backend.hcl.example`:

```hcl
# cp backend.hcl.example backend.hcl   (backend.hcl is gitignored)
# terraform init -backend-config=backend.hcl

bucket     = "obs-platform-tfstate-123456789012"
region     = "eu-west-1"
kms_key_id = "arn:aws:kms:eu-west-1:123456789012:key/REPLACE-ME"
```

`terraform/envs/prod-platform/variables.tf`:

```hcl
###############################################################################
# envs/prod-platform — input variables
###############################################################################

variable "aws_region" {
  description = "Region both clusters run in."
  type        = string
  default     = "eu-west-1"
}

variable "allowed_account_ids" {
  description = "Guard rail: refuse to run against any other account."
  type        = list(string)
}

# --- Where the infrastructure state lives ------------------------------------

variable "infra_state_bucket" {
  description = "S3 bucket holding the envs/prod state. Same bucket as this root module's own backend."
  type        = string
}

variable "infra_state_key" {
  description = "Key of the envs/prod state object."
  type        = string
  default     = "prod/platform.tfstate"
}

# --- Naming --------------------------------------------------------------------

variable "private_zone_name" {
  description = "Private hosted zone for cross-cluster service discovery."
  type        = string
  default     = "observability.internal"
}

variable "gateway_hostname" {
  description = "Leftmost label of the gateway record. The full name becomes <gateway_hostname>.<private_zone_name>."
  type        = string
  default     = "gateway"
}

variable "telemetry_namespace" {
  description = "Namespace the agent and the gateway each run in, on their own clusters."
  type        = string
  default     = "telemetry"
}

# --- Pinned versions -----------------------------------------------------------
#
# Every one of these must match a tag that scripts/mirror-images.sh has already
# pushed into ECR, or the release fails to pull.

variable "alloy_chart_version" {
  description = "Alloy chart version. Matches ALLOY_CHART_VERSION in scripts/mirror-images.sh."
  type        = string
  default     = "1.4.0"
}

variable "alloy_image_tag" {
  description = "Alloy image tag. Matches ALLOY_IMAGE_TAG in scripts/mirror-images.sh."
  type        = string
  default     = "v1.12.0"
}

variable "alb_chart_version" {
  description = "AWS Load Balancer Controller chart version. Matches ALB_CHART_VERSION in scripts/mirror-images.sh."
  type        = string
  default     = "1.13.4"
}

variable "alb_image_tag" {
  description = "AWS Load Balancer Controller image tag. Matches ALB_IMAGE_TAG and the iam-policy.json tag in modules/aws-lb-controller."
  type        = string
  default     = "v2.13.4"
}

variable "cert_manager_version" {
  description = "cert-manager chart and image version. Matches CERT_MANAGER_VERSION in scripts/mirror-images.sh."
  type        = string
  default     = "v1.19.1"
}

# --- Pipeline ------------------------------------------------------------------

variable "gateway_replicas" {
  description = "Gateway replicas on Cluster B."
  type        = number
  default     = 2
}

variable "lgtm_enabled" {
  description = <<-EOT
    Route gateway output to Mimir, Loki and Tempo instead of the debug sink.
    Leave false until the LGTM stack exists in Cluster B; until then the debug
    sink in the gateway's pod logs is how arrival is confirmed.
  EOT
  type        = bool
  default     = false
}

variable "mimir_endpoint" {
  description = "Mimir OTLP endpoint inside Cluster B. Only used when lgtm_enabled is true."
  type        = string
  default     = "http://mimir-nginx.lgtm.svc.cluster.local/otlp"
}

variable "loki_endpoint" {
  description = "Loki OTLP endpoint inside Cluster B. Only used when lgtm_enabled is true."
  type        = string
  default     = "http://loki-gateway.lgtm.svc.cluster.local/otlp"
}

variable "tempo_endpoint" {
  description = "Tempo OTLP/gRPC endpoint inside Cluster B. Only used when lgtm_enabled is true."
  type        = string
  default     = "tempo-distributor.lgtm.svc.cluster.local:4317"
}

variable "scrape_interval" {
  description = "kubelet and cAdvisor scrape interval on Cluster A."
  type        = string
  default     = "60s"
}
```

- [ ] **Step 2: Write the data sources and locals**

`terraform/envs/prod-platform/data.tf`:

```hcl
###############################################################################
# envs/prod-platform — what this layer reads from the layer below
#
# The infrastructure state is the contract. Cluster CA data and the OIDC issuer
# are looked up live rather than read from state, so envs/prod needs no new
# outputs and the values cannot go stale between applies.
###############################################################################

data "terraform_remote_state" "infra" {
  backend = "s3"

  config = {
    bucket = var.infra_state_bucket
    key    = var.infra_state_key
    region = var.aws_region
  }
}

data "aws_eks_cluster" "workload" {
  name = local.infra.clusters.workload.name
}

data "aws_eks_cluster" "observability" {
  name = local.infra.clusters.observability.name
}

data "aws_ecr_authorization_token" "this" {}
```

`terraform/envs/prod-platform/locals.tf`:

```hcl
###############################################################################
# envs/prod-platform — naming and derived values
###############################################################################

locals {
  infra = data.terraform_remote_state.infra.outputs.platform

  workload_cluster_name      = local.infra.clusters.workload.name
  observability_cluster_name = local.infra.clusters.observability.name

  # <account>.dkr.ecr.<region>.amazonaws.com — see modules/ecr's registry_url.
  registry       = local.infra.registry
  chart_registry = "oci://${local.registry}/charts"

  gateway_dns_name = "${var.gateway_hostname}.${var.private_zone_name}"

  # The OIDC issuer without its scheme is the exact string an IRSA trust policy
  # uses as a condition key prefix.
  workload_oidc_host      = replace(data.aws_eks_cluster.workload.identity[0].oidc[0].issuer, "https://", "")
  observability_oidc_host = replace(data.aws_eks_cluster.observability.identity[0].oidc[0].issuer, "https://", "")

  common_tags = {
    Project     = local.infra.clusters.workload.name
    Environment = local.infra.environment
    Layer       = "kubernetes-platform"
  }
}
```

- [ ] **Step 3: Write the providers**

`terraform/envs/prod-platform/providers.tf`:

```hcl
###############################################################################
# envs/prod-platform — providers
#
# Four aliased providers, one per (tool, cluster) pair. Every module call names
# the cluster it targets explicitly, so there is no default provider to
# accidentally deploy the agent into the observability cluster.
#
# The clusters already exist when this root module runs — that is the entire
# reason it is a separate root module. Deriving provider configuration from
# resources created in the same apply plans badly on green-field and worse on
# destroy.
#   docs/adr/0008-two-stage-terraform.md
###############################################################################

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Environment = local.infra.environment
      ManagedBy   = "terraform"
      Layer       = "kubernetes-platform"
    }
  }
}

# --- Cluster A (workload) --------------------------------------------------------

provider "kubernetes" {
  alias = "workload"

  host                   = data.aws_eks_cluster.workload.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.workload.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.workload_cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  alias = "workload"

  kubernetes = {
    host                   = data.aws_eks_cluster.workload.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.workload.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.workload_cluster_name, "--region", var.aws_region]
    }
  }

  # Charts live in ECR, not on a public chart repository (ADR 0005). The token
  # is short-lived and re-read on every plan.
  registries = [
    {
      url      = local.chart_registry
      username = data.aws_ecr_authorization_token.this.user_name
      password = data.aws_ecr_authorization_token.this.password
    },
  ]
}

# --- Cluster B (observability) ---------------------------------------------------

provider "kubernetes" {
  alias = "observability"

  host                   = data.aws_eks_cluster.observability.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.observability.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.observability_cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  alias = "observability"

  kubernetes = {
    host                   = data.aws_eks_cluster.observability.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.observability.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.observability_cluster_name, "--region", var.aws_region]
    }
  }

  registries = [
    {
      url      = local.chart_registry
      username = data.aws_ecr_authorization_token.this.user_name
      password = data.aws_ecr_authorization_token.this.password
    },
  ]
}
```

- [ ] **Step 4: Write the wiring**

`terraform/envs/prod-platform/main.tf`:

```hcl
###############################################################################
# envs/prod-platform — the Kubernetes layer
#
#   dns-private-zone    x1  -> observability.internal, both VPCs
#   aws-lb-controller   x1  -> Cluster B, so a Service can become an NLB
#   cert-manager        x1  -> Cluster B, issues the gateway certificate
#   telemetry-gateway   x1  -> Cluster B, TLS + auth + fan-out
#   telemetry-agent     x1  -> Cluster A, collects and ships
#
# Modules never call each other. This file is the only place the two clusters
# meet, and it is the only place that knows the gateway's name, CA and
# credential travel from B to A.
#
# Design rationale:
#   docs/superpowers/specs/2026-08-21-cross-cluster-telemetry-pipeline-design.md
#   docs/adr/0006  Alloy as the unified agent
#   docs/adr/0007  internal NLB plus a dual-associated private zone
#   docs/adr/0008  two-stage Terraform
###############################################################################

###############################################################################
# 1. NAME RESOLUTION
#
# Associated with BOTH VPCs. Without the workload association, a query from
# Cluster A leaks past the VPC resolver and returns NXDOMAIN — the single most
# likely way this pipeline fails to come up.
###############################################################################

module "dns" {
  source = "../../modules/dns-private-zone"

  zone_name      = var.private_zone_name
  primary_vpc_id = local.infra.clusters.observability.vpc_id
  additional_vpc_ids = [
    local.infra.clusters.workload.vpc_id,
  ]

  tags = local.common_tags
}

###############################################################################
# 2. CLUSTER B ADD-ONS
###############################################################################

module "lb_controller" {
  source = "../../modules/aws-lb-controller"

  providers = {
    helm = helm.observability
  }

  cluster_name       = local.observability_cluster_name
  vpc_id             = local.infra.clusters.observability.vpc_id
  region             = var.aws_region
  oidc_provider_arn  = local.infra.clusters.observability.oidc_provider_arn
  oidc_provider_host = local.observability_oidc_host

  chart_repository = local.chart_registry
  chart_version    = var.alb_chart_version
  image_repository = "${local.registry}/mirror/eks/aws-load-balancer-controller"
  image_tag        = var.alb_image_tag

  tags = local.common_tags
}

module "cert_manager" {
  source = "../../modules/cert-manager"

  providers = {
    helm       = helm.observability
    kubernetes = kubernetes.observability
  }

  chart_repository = local.chart_registry
  chart_version    = var.cert_manager_version
  image_registry   = local.registry
}

###############################################################################
# 3. THE GATEWAY — Cluster B
#
# Depends on both add-ons: the controller has to exist before a Service of type
# LoadBalancer reconciles into anything, and cert-manager has to be serving
# before a Certificate is admitted.
###############################################################################

module "gateway" {
  source = "../../modules/telemetry-gateway"

  providers = {
    helm       = helm.observability
    kubernetes = kubernetes.observability
  }

  cluster_name     = local.observability_cluster_name
  namespace        = var.telemetry_namespace
  gateway_dns_name = local.gateway_dns_name
  route53_zone_id  = module.dns.zone_id

  cert_manager_namespace = module.cert_manager.namespace

  nlb_subnet_ids = data.terraform_remote_state.infra.outputs.observability_private_subnet_ids

  # The group modules/security already builds. Putting it on the load balancer
  # is what gives the workload-VPC CIDR restriction teeth.
  nlb_security_group_ids = [
    data.terraform_remote_state.infra.outputs.otlp_security_group_ids.observability_ingress,
  ]

  chart_repository = local.chart_registry
  chart_version    = var.alloy_chart_version
  image_repository = "${local.registry}/mirror/grafana/alloy"
  image_tag        = var.alloy_image_tag

  replicas = var.gateway_replicas

  lgtm_enabled   = var.lgtm_enabled
  mimir_endpoint = var.mimir_endpoint
  loki_endpoint  = var.loki_endpoint
  tempo_endpoint = var.tempo_endpoint

  tags = local.common_tags

  depends_on = [
    module.lb_controller,
    module.cert_manager,
  ]
}

###############################################################################
# 4. THE AGENT — Cluster A
#
# Everything Cluster A learns about Cluster B passes through here: a name, a CA
# and a credential. The agent module itself has no knowledge of the other
# cluster at all.
###############################################################################

module "agent" {
  source = "../../modules/telemetry-agent"

  providers = {
    helm       = helm.workload
    kubernetes = kubernetes.workload
  }

  cluster_name = local.workload_cluster_name
  namespace    = var.telemetry_namespace

  gateway_endpoint = module.gateway.gateway_endpoint
  gateway_ca_pem   = module.gateway.ca_certificate_pem
  ingest_username  = module.gateway.ingest_username
  ingest_password  = module.gateway.ingest_password

  chart_repository = local.chart_registry
  chart_version    = var.alloy_chart_version
  image_repository = "${local.registry}/mirror/grafana/alloy"
  image_tag        = var.alloy_image_tag

  scrape_interval = var.scrape_interval
}
```

- [ ] **Step 5: Write the outputs**

`terraform/envs/prod-platform/outputs.tf`:

```hcl
###############################################################################
# envs/prod-platform — outputs
###############################################################################

output "gateway_dns_name" {
  description = "Name Cluster A connects to, and the SAN on the gateway certificate."
  value       = module.gateway.gateway_dns_name
}

output "gateway_endpoint" {
  description = "host:port the agent exports to."
  value       = module.gateway.gateway_endpoint
}

output "nlb_hostname" {
  description = "AWS-generated name of the internal NLB. Compare against what the CNAME resolves to when diagnosing a resolution failure."
  value       = module.gateway.nlb_hostname
}

output "private_zone_id" {
  description = "Hosted zone ID. Section 3's LGTM services get their names here too."
  value       = module.dns.zone_id
}

output "agent_otlp_endpoint" {
  description = "In-cluster OTLP endpoint on Cluster A. Point the Boutique's OTEL_EXPORTER_OTLP_ENDPOINT here."
  value       = module.agent.otlp_endpoint
}

output "telemetry_namespace" {
  description = "Namespace the agent and gateway run in, on their respective clusters."
  value       = var.telemetry_namespace
}

# The runbook's checks, rendered with this deployment's actual names so they
# can be copied and run without editing.
output "verification" {
  description = "Ready-to-run commands that prove the pipeline works end to end."
  value = {
    "1_resolve" = "kubectl --context ${local.workload_cluster_name} -n ${var.telemetry_namespace} exec -it ds/alloy-agent -- nslookup ${module.gateway.gateway_dns_name}"
    "2_agent_logs" = "kubectl --context ${local.workload_cluster_name} -n ${var.telemetry_namespace} logs -l app.kubernetes.io/name=alloy --tail=50"
    "3_agent_sent" = "kubectl --context ${local.workload_cluster_name} -n ${var.telemetry_namespace} exec -it ds/alloy-agent -- wget -qO- localhost:12345/metrics | grep otelcol_exporter_send"
    "4_gateway_received" = "kubectl --context ${local.observability_cluster_name} -n ${var.telemetry_namespace} logs -l app.kubernetes.io/name=alloy --tail=50"
    "5_reject_anonymous"  = "kubectl --context ${local.workload_cluster_name} -n ${var.telemetry_namespace} exec -it ds/alloy-agent -- wget -qO- --post-data='{}' --header='Content-Type: application/json' https://${module.gateway.gateway_dns_name}:4318/v1/traces"
  }
}
```

- [ ] **Step 6: Write the tfvars example**

`terraform/envs/prod-platform/terraform.tfvars.example`:

```hcl
###############################################################################
# cp terraform.tfvars.example terraform.tfvars   (terraform.tfvars is gitignored)
#
# Apply order is not optional:
#   1. cd ../prod && terraform apply     (the clusters must exist)
#   2. cd ../.. && make mirror           (the charts must be in ECR)
#   3. make platform-init && make platform-apply
###############################################################################

aws_region          = "eu-west-1"
allowed_account_ids = ["123456789012"]

# Same bucket as this root module's own backend; different key.
infra_state_bucket = "obs-platform-tfstate-123456789012"
infra_state_key    = "prod/platform.tfstate"

# --- Naming ----------------------------------------------------------------------
private_zone_name   = "observability.internal"
gateway_hostname    = "gateway"
telemetry_namespace = "telemetry"

# --- Pinned versions -------------------------------------------------------------
# Each must already exist in ECR. Bump here and in scripts/mirror-images.sh
# together, then re-run `make mirror` before applying.
alloy_chart_version  = "1.4.0"
alloy_image_tag      = "v1.12.0"
alb_chart_version    = "1.13.4"
alb_image_tag        = "v2.13.4"
cert_manager_version = "v1.19.1"

# --- Pipeline --------------------------------------------------------------------
gateway_replicas = 2
scrape_interval  = "60s"

# Leave false until the LGTM stack exists in Cluster B. While false the gateway
# prints arriving telemetry to its own logs, which is how the pipeline is
# verified before Section 3 lands.
lgtm_enabled = false
```

- [ ] **Step 7: Add the platform targets to the Makefile**

Add `platform-init platform-plan platform-apply platform-destroy` to `.PHONY` and append:

```makefile
PLATFORM_DIR := envs/prod-platform

platform-init: ## Initialise the Kubernetes layer against the S3 backend
	cd $(PLATFORM_DIR) && terraform init -backend-config=backend.hcl -reconfigure

platform-plan: ## Plan the Kubernetes layer (envs/prod must be applied first)
	cd $(PLATFORM_DIR) && terraform plan -out=tfplan

platform-apply: ## Apply the Kubernetes layer
	cd $(PLATFORM_DIR) && terraform apply tfplan

platform-destroy: ## Destroy the Kubernetes layer. Run BEFORE destroying envs/prod.
	cd $(PLATFORM_DIR) && terraform destroy

verify: ## Print the end-to-end verification commands for the telemetry pipeline
	cd $(PLATFORM_DIR) && terraform output -json verification | jq -r 'to_entries|sort_by(.key)|.[]|"\(.key):\n  \(.value)\n"'
```

Also extend the existing `validate` target so it covers the new root module:

```makefile
validate: ## Validate every root module (no backend, no credentials needed)
	cd $(DIR) && terraform init -backend=false -input=false >/dev/null && terraform validate
	cd $(PLATFORM_DIR) && terraform init -backend=false -input=false >/dev/null && terraform validate
	cd bootstrap && terraform init -backend=false -input=false >/dev/null && terraform validate
```

- [ ] **Step 8: Validate the root module**

The root module reads live AWS state, so it is validated rather than unit-tested; the modules it calls carry the assertions.

```bash
cd terraform && terraform fmt -recursive && make validate
```

Expected: `Success! The configuration is valid.` three times — `envs/prod`, `envs/prod-platform`, `bootstrap`.

- [ ] **Step 9: Confirm every module is still green**

```bash
cd terraform && make test
```

Expected: `Success!` for all six modules.

- [ ] **Step 10: Commit**

```bash
cd /home/muhammad/devops_practice/devops-project3
cd terraform && terraform fmt -recursive && cd ..
git add terraform/envs/prod-platform terraform/Makefile
git commit -m "feat(terraform): wire the Kubernetes platform root module

Four aliased providers, one per tool and cluster, so every module call
names the cluster it targets and there is no default provider to deploy
the agent into the wrong one.

It reads envs/prod through remote state but looks the cluster CA and
OIDC issuer up live, so envs/prod needs no new outputs and the values
cannot go stale between applies.

The gateway hands its name, CA and credential to the agent here. That
transfer is the only place the two clusters meet; neither telemetry
module knows the other exists.

The verification output renders the runbook's checks with this
deployment's real names, so they can be copied and run without editing.
Applying this before envs/prod, or before make mirror, will not work,
and the tfvars example says so at the top."
```

---

### Task 9: Decision records and the runbook

The rubric weights documentation at 15% and justified decisions at every turn. Three decisions were made in this work that a reader cannot recover from the code.

**Files:**
- Create: `docs/adr/0006-telemetry-agent-selection.md`
- Create: `docs/adr/0007-cross-cluster-name-resolution.md`
- Create: `docs/adr/0008-two-stage-terraform.md`
- Create: `docs/RUNBOOK-telemetry.md`
- Modify: `docs/README.md`
- Modify: `terraform/README.md`

**Interfaces:**
- Consumes: every decision made in Tasks 1–8.
- Produces: nothing code depends on. The module header comments written in Tasks 1–8 already reference these paths, so the cross-references resolve once this task lands.

- [ ] **Step 1: Write ADR 0006 — the agent choice**

Create `docs/adr/0006-telemetry-agent-selection.md`, matching the house style of ADRs 0001–0005 exactly: `**Status:**`, `**Date:**`, `**Implemented by:**`, then `## Context`, `## Decision`, `## Consequences`, `## Alternatives considered` with a comparison table.

Content it must cover:
- **Context.** Three signals, one cluster fleet, and a brief that names both the upstream OpenTelemetry Collector and Grafana Alloy as acceptable.
- **Decision.** Grafana Alloy as a single DaemonSet.
- The upstream Collector handles OTLP well, but Kubernetes infrastructure metrics and pod logs conventionally need a Prometheus agent and Promtail alongside it — three agents, three configs, three failure modes on every node.
- Alloy is an OTLP-compatible Collector distribution with native `prometheus.scrape` and `loki.source.file` components plus `otelcol.receiver.prometheus` and `otelcol.receiver.loki` bridges, so all three signals become OTLP in-process and leave on one connection. That is what keeps the peering link at two ports.
- Its configuration language is HCL-shaped, which matches the rest of this repository.
- **Consequences.** A Grafana-specific distribution rather than pure upstream; the component names are Alloy's, not the Collector's, so an upstream Collector config does not port over unchanged. Against that, one DaemonSet, one config, one set of metrics to alert on.
- **Alternatives table:** upstream OTel Collector + Prometheus agent + Promtail | OTel Collector alone (loses logs and infra metrics) | **Grafana Alloy** (chosen) | Grafana Agent (superseded by Alloy).

- [ ] **Step 2: Write ADR 0007 — name resolution**

Create `docs/adr/0007-cross-cluster-name-resolution.md`, same structure.

Content it must cover:
- **Context.** ADR 0002 settled the transport. It did not settle how Cluster A finds the gateway: two clusters share no DNS namespace, and `svc.cluster.local` names are meaningless across a peering link.
- **Decision.** An internal NLB in Cluster B's private subnets, plus a Route 53 private hosted zone associated with **both** VPCs, plus a CNAME.
- The full resolution chain, step by step, as written in §4 of the spec — reproduce it here, because it is the thing an on-call engineer needs at 3am.
- Why no CoreDNS change: a stub domain or a `forward` plugin edit is a ConfigMap the EKS CoreDNS add-on rewrites on upgrade. Resolution below Kubernetes survives that.
- Why a CNAME rather than an alias record: the NLB is created by the AWS Load Balancer Controller in response to a Service, so its hosted zone ID is not a value Terraform holds at that point.
- Why the security group is on the load balancer and not only on the nodes: NLB `ip` targets do not preserve the client IP by default, so a node-attached group never observes Cluster A's address and a CIDR rule there silently matches nothing.
- **Consequences.** The NLB carries an hourly charge, unlike raw peering — the one running cost this design adds. `allow_remote_vpc_dns_resolution` must stay enabled on both sides of the peering connection. The zone name must stay `.internal`, or a name that could exist publicly will resolve publicly wherever the zone is not associated, which fails open.
- **Alternatives table:** CoreDNS stub domain | hardcoded NLB address | public endpoint | **private zone + internal NLB** (chosen).

- [ ] **Step 3: Write ADR 0008 — two-stage Terraform**

Create `docs/adr/0008-two-stage-terraform.md`, same structure.

Content it must cover:
- **Context.** The Helm and Kubernetes providers need a cluster endpoint and credentials to configure themselves. Those values come from resources `envs/prod` creates.
- **Decision.** A second root module, `envs/prod-platform`, with its own state key in the same bucket.
- Provider configuration derived from resources in the same apply is unknown at plan time on a green-field run, and on destroy the provider is reconfigured from state that is being torn down underneath it.
- Blast radius: a failed Helm release cannot leave the infrastructure state partially applied.
- It matches the CI shape Section 4 needs — two ordered jobs, the second gated on the first.
- **Consequences.** Apply order is now load-bearing and must be documented; `make platform-destroy` has to run before `make destroy` or the platform state references clusters that no longer exist. Two states mean two locks and two `init` invocations.
- **Alternatives table:** single root module | `-target` on the first apply | GitOps controller (Argo CD / Flux) | **two root modules** (chosen). Note that GitOps is the honest long-term answer and what to revisit if the platform grows past a handful of releases.

- [ ] **Step 4: Write the runbook**

Create `docs/RUNBOOK-telemetry.md` with these sections:

1. **What this is** — one paragraph and the flow `Cluster A pods → Alloy DaemonSet → NLB → Gateway Alloy → LGTM`, with a link to the spec's Mermaid diagram.
2. **Deploy, in order** — the four commands, with the reason each ordering constraint exists:
   ```
   cd terraform && make init && make plan && make apply     # clusters
   make mirror                                              # charts into ECR
   make platform-init && make platform-plan && make platform-apply
   make verify                                              # prints the checks below
   ```
3. **Verify** — the five checks from §10 of the spec, each with the exact command, the expected output, and what a failure at that step means:
   - `nslookup gateway.observability.internal` returns an address inside the observability VPC CIDR. **Fails here** → the zone is not associated with the workload VPC, or `allow_remote_vpc_dns_resolution` is off.
   - `openssl s_client -connect <name>:4317 -CAfile ca.crt` verifies chain and SAN. **Fails here** → certificate SAN does not match the record, or the NLB has no healthy targets.
   - An unauthenticated POST to `:4318/v1/traces` is rejected. **Succeeds here** → the receiver's `auth` handler is missing on the HTTP block; treat as a security incident, not a bug.
   - Agent `/metrics` shows `otelcol_exporter_sent_spans` climbing and `otelcol_exporter_send_failed_spans` flat. **Failing counter climbing** → auth or TLS, and the agent's own logs say which.
   - Gateway pod logs print spans carrying `cluster=<workload cluster name>`. **This is the definition of done.**
4. **Troubleshooting** — a symptom → cause → fix table:
   | Symptom | Likely cause | Fix |
   | `NXDOMAIN` for the gateway name | zone not associated with the workload VPC | check `module.dns` associations |
   | resolves to a public address | `allow_remote_vpc_dns_resolution` disabled | it is set in `modules/security`; confirm the peering options applied |
   | connection times out | route table missing the peer route, or the SG is not on the NLB | `terraform output otlp_security_group_ids`, check the Service annotation |
   | `x509: certificate is valid for ...` | SAN does not match the record | `gateway_dns_name` and the certificate must be the same string |
   | `401`/`Unauthenticated` on every batch | credential drift between the two Secrets | re-apply `prod-platform`; both Secrets come from one `random_password` |
   | agent `CrashLoopBackOff` on start | Alloy config error | `kubectl logs` prints the offending line and column |
   | gateway pods `Pending` | the tls Secret does not exist yet | cert-manager has not issued; check `kubectl get certificate -A` |
5. **Rotating the ingest credential** — `terraform taint 'module.gateway.random_password.ingest'` then apply; both Secrets and both releases update in one run.
6. **Teardown** — `make platform-destroy` **before** `make destroy`, and why: the platform state's providers are configured from clusters that the infrastructure destroy removes.
7. **Cost note** — the internal NLB is the one hourly charge this layer adds on top of the two clusters. Tear it down between test runs.

- [ ] **Step 5: Update the documentation index**

In `docs/README.md`, add three rows to the ADR table:

```markdown
| [0006](adr/0006-telemetry-agent-selection.md) | Grafana Alloy as the unified telemetry agent, over the upstream Collector plus two more agents |
| [0007](adr/0007-cross-cluster-name-resolution.md) | Internal NLB plus a dual-associated private zone, over CoreDNS stub domains |
| [0008](adr/0008-two-stage-terraform.md) | Two Terraform root modules — infrastructure, then the Kubernetes layer |
```

And add to the `## Related` list:

```markdown
- [`RUNBOOK-telemetry.md`](RUNBOOK-telemetry.md) — deploy, verify and troubleshoot the telemetry pipeline
- [`superpowers/specs/2026-08-21-cross-cluster-telemetry-pipeline-design.md`](superpowers/specs/2026-08-21-cross-cluster-telemetry-pipeline-design.md) — the pipeline's design
```

- [ ] **Step 6: Update the Terraform README**

In `terraform/README.md`:
- Add the six new modules to the module table with one-line purposes.
- Add an "Apply order" section stating the two stages and that `make mirror` sits between them.
- Add the internal NLB to the cost table.
- Cross-link ADRs 0006, 0007 and 0008.

- [ ] **Step 7: Verify every cross-reference resolves**

The module headers written in Tasks 1–8 reference these documents by path. A stale link is exactly the defect ADR 0002's own history records.

```bash
cd /home/muhammad/devops_practice/devops-project3
grep -rhoE 'docs/(adr/[0-9]{4}-[a-z-]+\.md|[A-Z-]+\.md|superpowers/specs/[0-9a-z-]+\.md)' \
  terraform/ docs/ charts/ 2>/dev/null | sort -u | while read -r f; do
  [ -f "$f" ] || echo "BROKEN: $f"
done
echo "link check complete"
```

Expected: `link check complete` with no `BROKEN:` lines.

- [ ] **Step 8: Final full verification**

```bash
cd terraform && terraform fmt -check -recursive && make validate && make test
cd .. && ./charts/telemetry-certs/test.sh && bash -n scripts/mirror-images.sh
```

Expected: `fmt -check` silent, three `Success! The configuration is valid.`, six module suites green, `chart ok`.

- [ ] **Step 9: Commit**

```bash
cd /home/muhammad/devops_practice/devops-project3
git add docs terraform/README.md
git commit -m "docs: record the telemetry pipeline's decisions and runbook

Three decisions in this layer cannot be recovered from the code. Why
Alloy rather than the upstream Collector plus a Prometheus agent and
Promtail. Why a private hosted zone and an internal NLB rather than a
CoreDNS stub domain that an add-on upgrade would overwrite. Why the
Kubernetes layer is a second root module rather than more resources in
the first.

The runbook carries the resolution chain step by step and a symptom
table, because the failure modes here are mostly DNS and certificate
mismatches that read like network faults and are not."
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task: §4 name resolution → Tasks 3 and 6; §5 TLS and auth → Tasks 5, 6, 7; §6 Terraform layout → Tasks 1–8; §7 the agent → Task 7; §8 the gateway → Task 6; §9 supply chain → Task 2; §10 verification → the test steps throughout plus Task 9's runbook; §11 risks → mitigated in code (`time_sleep`, `wait = true`, the `gateway_ca_pem` validation, the ordered Makefile targets); §12 follow-on ADRs → Task 9.

**Type and name consistency, checked across tasks.** `role_arn`/`role_name`/`assume_role_policy_json` (Task 1) are consumed by Task 4. `zone_id` (Task 3) is consumed by Task 8 and passed to Task 6 as `route53_zone_id`. `namespace` (Task 5) is consumed as `cert_manager_namespace` in Task 6. `gateway_endpoint`, `ca_certificate_pem`, `ingest_username`, `ingest_password` (Task 6) are consumed as `gateway_endpoint`, `gateway_ca_pem`, `ingest_username`, `ingest_password` in Task 7 — the CA output and input names differ deliberately and are wired explicitly in Task 8's `module "agent"` block. Every module exposes `rendered_values`; the two Alloy modules also expose `rendered_config`. The secret names `telemetry-ca-key-pair` and `telemetry-gateway-tls` are set in Task 5's `values.yaml` and overridden identically from Task 6's `helm_release.certs` values.

**Version pinning consistency.** `ALLOY_CHART_VERSION`/`ALLOY_IMAGE_TAG`/`ALB_CHART_VERSION`/`ALB_IMAGE_TAG`/`CERT_MANAGER_VERSION` in Task 2's script are repeated as defaults in Task 8's variables and in its tfvars example. The `v2.13.4` in Task 4's `iam-policy.json` URL matches `ALB_IMAGE_TAG`. Task 8's variable descriptions name the script explicitly so the coupling is visible from either end.
