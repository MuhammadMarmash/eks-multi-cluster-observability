# Final Project Mission: Production-Grade Multi-Cluster Observability on AWS EKS

**Audience:** Senior DevOps Students  
**Format:** Markdown brief — what to build, not how. No code snippets in this document.

---

## Project Scope

| | |
|---|---|
| **Team size** | 1 student 
| **Due date** | **September 1, 2026** |
| **AWS budget** | Each team is allocated a shared AWS account. Keep total spend under **$50**. Use `t3.medium` nodes (2 per cluster is sufficient for testing). **Destroy all resources when not actively testing** — idle EKS clusters cost ~$0.10/hr each. |

---

## Grading Rubric

| Area | Weight | What we look for |
|---|---|---|
| **Infrastructure (IaC)** | 25% | Terraform correctness, module structure, remote state, reproducibility |
| **Data Pipeline** | 25% | Telemetry actually flows from Cluster A → Cluster B; networking choice is justified |
| **Security** | 20% | IRSA, TLS, least-privilege IAM, no secrets committed, S3 encryption |
| **Documentation** | 15% | Architecture diagram, justified decisions, runbook quality |
| **Day 2 Operations** | 15% | EKS upgrade strategy and Mimir HPA (see Section 5) |

---

## Mission Statement

As your CTO, I am assigning you the design, implementation, and documentation of a **production-grade, multi-cluster observability solution** on AWS EKS. You will use **Terraform** for infrastructure and the **LGTM stack** (Loki, Grafana, Tempo, Mimir) as the observability backbone. This is not a lab exercise—treat it as a real deployment that would run in a scaling startup environment. Your architecture decisions, security posture, and operational runbooks will be evaluated accordingly.

---

## 1. The Infrastructure (IaC)

- **Terraform** must be the single source of truth for all AWS and EKS provisioning. No manual cluster creation.
- Provision **two separate EKS clusters** in AWS:
  - **Cluster A (Workload):** Hosts the **Google Online Boutique** microservices demo. This cluster represents your application fleet; it must be deployable, reachable, and instrumented. Note: the Online Boutique application is already instrumented with OpenTelemetry — you do not need to modify application code.
  - **Cluster B (Observability HQ):** Hosts the **centralized LGTM stack** (Loki, Grafana, Tempo, Mimir). This cluster is the single pane of glass for metrics, logs, and traces.
- Document your Terraform module layout (e.g., separate modules for VPC, EKS, add-ons). State management and remote backends are your responsibility—choose and justify your approach.
- You must determine where to host **Docker images** and **Helm charts**. **AWS ECR is the expected choice**, not Docker Hub or public registries. In production, you never pull images directly from public sources — you mirror them into a private registry, run vulnerability scans (e.g., Amazon Inspector, Trivy), and enforce image signing. Your ECR repositories, scan-on-push policies, and any CI steps that push images must be documented.

---

## 2. The Data Pipeline

- **Metrics, logs, and traces** from Cluster A must be **securely shipped** to Cluster B. No data must reside only on Cluster A for long-term observability.
- You need a **telemetry forwarding agent** running on Cluster A to collect and ship data. Common choices include the **OpenTelemetry Collector** (for traces, and optionally metrics/logs) and **Grafana Alloy** (a unified agent for all three signals). The choice and configuration is yours — justify it.
- You are required to **choose and implement a networking strategy** for cross-cluster communication. Options include (but are not limited to):
  - **Public endpoints** with strict security groups and encryption in transit.
  - **VPC Peering** between the two clusters' VPCs.
  - **AWS PrivateLink** for private, scalable exposure of Observability HQ services.
- Justify your choice in the README: trade-offs (cost, complexity, security, operational burden) must be clearly explained. The pipeline must be production-appropriate (auth, TLS, least-privilege access).

---

## 3. The "Cloud Native" Storage

- **No long-term reliance on local or node-attached disks** for observability data. All durable storage for the LGTM stack must be **AWS S3** (or S3-compatible) for:
  - **Mimir** (metrics)
  - **Loki** (logs)
  - **Tempo** (traces)
- Implement **IRSA (IAM Roles for Service Accounts)** so that Loki, Grafana, Tempo, and Mimir components can **securely access S3** without long-lived access keys. Document which service accounts and IAM roles map to which components.
- Bucket naming, lifecycle policies, and encryption (SSE-S3 or SSE-KMS) are your design decisions—document them.

---

## 4. CI/CD & GitOps

- The **final submission** must be a **GitHub repository** (or, if your cohort uses it, GitLab—adjust accordingly).
- Include a **working CI/CD pipeline** (e.g., GitHub Actions or GitLab CI) that:
  - **Lints** and **plans** Terraform (and optionally applies in a controlled way).
  - **Deploys or prepares** Helm chart releases for the LGTM stack and/or the Boutique app (strategy is up to you: apply in CI vs. GitOps sync).
- The pipeline must be reproducible: another engineer should be able to re-run it from the repo. Secrets (e.g., AWS credentials, Grafana admin password) must be handled via the platform's secret store, not committed.

---

## 5. Day 2 Operations

This section is **required**, not optional. Operational maturity is what separates a working prototype from a production system.

- **Upgrades:** Describe the **strategy for upgrading EKS versions** with **zero downtime** for the observability data. Consider control plane upgrades, node group rollouts, and how you would avoid gaps in metrics/logs/traces during the cutover.
- **Scaling:** **Implement or describe** how to use **Horizontal Pod Autoscaler (HPA)** for the **Mimir Ingesters** based on **custom metrics** (e.g., from Prometheus/Mimir). The goal is to show that the observability stack itself can scale with load.

---

## 6. Deliverables

Your repository must include:

| Deliverable | Description |
|-------------|-------------|
| **README.md** | Professional overview with a **clear architecture diagram** (e.g., draw.io, Mermaid, or similar) showing both clusters, data flow, and storage. |
| **Terraform** | All `.tf` files (and any `.tfvars` or backend config) needed to reproduce the two EKS clusters and supporting AWS resources. |
| **Helm** | All `values.yaml` (or equivalent) files used to deploy the LGTM stack and the Google Online Boutique on their respective clusters. |
| **Proof of Life** | A **"Proof of Life"** section in the README: a **screenshot of a Grafana dashboard in Cluster B** showing **traces** and **metrics** originating from **Cluster A** (e.g., Boutique services). This is the non-negotiable evidence that the pipeline works end-to-end. |

---

## 7. Tone & Expectations

- **Professional and real-world:** Assume this will be reviewed by a staff engineer or CTO. Naming, documentation, and security choices matter.
- **Demanding:** We expect justified design decisions, not "it worked on my machine." Think production: backups, encryption, least privilege, and upgrade paths.
- **Ownership:** You are responsible for your image supply chain (ECR), your secrets management, your state backend, and your cost. These are not afterthoughts — they are part of the grade.

---

*Good luck. Build something you'd be proud to run in production.*

— **Naim Salameh**
