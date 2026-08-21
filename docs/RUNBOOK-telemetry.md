# Runbook — the cross-cluster telemetry pipeline

Metrics, logs and traces from Cluster A, shipped as OTLP over the VPC peering link to a
gateway in Cluster B that terminates TLS and authentication and fans out to the LGTM stack.

```
Cluster A pods ──▶ Alloy DaemonSet ──▶ internal NLB ──▶ Gateway Alloy ──▶ Mimir / Loki / Tempo
   (OTLP)          (collects all 3,      (TCP :4317)     (TLS + auth      (Section 3)
                    converts to OTLP)                     terminate here)
```

Architecture and the reasoning behind each choice:
[the design spec](superpowers/specs/2026-08-21-cross-cluster-telemetry-pipeline-design.md),
[ADR 0002](adr/0002-cross-vpc-telemetry-transport.md),
[ADR 0006](adr/0006-telemetry-agent-selection.md),
[ADR 0007](adr/0007-cross-cluster-name-resolution.md),
[ADR 0008](adr/0008-two-stage-terraform.md).

---

## Deploy

Run from `terraform/`. **The order is not optional** — see
[ADR 0008](adr/0008-two-stage-terraform.md).

```bash
make init && make plan && make apply      # 1. the clusters must exist
make mirror                               # 2. the charts must be in ECR
make platform-init
make platform-plan && make platform-apply # 3. the Kubernetes layer
make verify                               # 4. prints the checks below, with real names
```

Why each gate exists:

- **`make apply` first** — the platform root's providers configure themselves from clusters
  that have to already be running.
- **`make mirror` second** — every chart and image reference points at ECR
  ([ADR 0005](adr/0005-container-supply-chain.md)). An unmirrored tag fails the release at
  pull time, several minutes in.
- **`make platform-apply` last** — and expect it to take 10–15 minutes. cert-manager has to
  come up and issue, then the NLB has to provision.

## Verify

`make verify` prints these with this deployment's actual cluster names substituted in.
Run them in order; each one tells you something different when it fails.

### 1. The name resolves, to a private address in Cluster B

```bash
kubectl -n telemetry exec ds/alloy-agent -- nslookup gateway.observability.internal
```

Expect an address inside the observability VPC CIDR (`10.1.0.0/16` by default).

**NXDOMAIN** → the private zone is not associated with the workload VPC. This is the single
most likely failure. Check `module.dns`'s `additional_vpc_ids`.
**A public address** → `allow_remote_vpc_dns_resolution` is off on the peering connection.
It is set in `modules/security`; confirm the options actually applied.

### 2. The certificate verifies, and the SAN matches

```bash
terraform -chdir=envs/prod-platform output -raw gateway_ca_certificate > /tmp/ca.crt
openssl s_client -connect gateway.observability.internal:4317 -CAfile /tmp/ca.crt </dev/null
```

Expect `Verify return code: 0 (ok)`.

**Times out** → routing or the security group. The route exists only in the *private*
subnets' tables, and the group has to be on the **NLB**, not only the nodes
([ADR 0007](adr/0007-cross-cluster-name-resolution.md)).
**`certificate is valid for ...`** → the SAN does not match the record. `gateway_dns_name`
and the certificate's `dnsNames` must be the same string.

### 3. Unauthenticated ingest is refused

The negative test, and the one most likely to be skipped.

```bash
kubectl -n telemetry exec ds/alloy-agent -- \
  wget -qO- --post-data='{}' --header='Content-Type: application/json' \
  https://gateway.observability.internal:4318/v1/traces
```

Expect a `401`. **If this succeeds, treat it as a security incident, not a bug** — the
`auth` handler is missing from the receiver's `http` block and the gateway has been
accepting anonymous telemetry.

### 4. The agent is sending, and not failing

```bash
kubectl -n telemetry exec ds/alloy-agent -- wget -qO- localhost:12345/metrics \
  | grep otelcol_exporter_send
```

Expect `otelcol_exporter_sent_spans` and `otelcol_exporter_sent_log_records` climbing, with
`otelcol_exporter_send_failed_*` flat.

**Failed counter climbing** → auth or TLS. The agent's own logs name which.

### 5. The gateway received it, stamped with Cluster A

```bash
kubectl --context <observability-cluster> -n telemetry logs -l app.kubernetes.io/name=alloy --tail=50
```

Expect the debug exporter printing spans whose resource attributes carry
`cluster=<workload-cluster-name>`.

**This is the definition of done.** Data left Cluster A, crossed the peering link,
authenticated, and arrived identifiable.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `NXDOMAIN` for the gateway name | zone not associated with the workload VPC | check `module.dns.additional_vpc_ids` |
| resolves to a public address | `allow_remote_vpc_dns_resolution` disabled | set in `modules/security`; confirm the peering options applied |
| connection times out | no peer route, or the SG is not on the NLB | `terraform output otlp_security_group_ids`; check the Service annotation |
| `x509: certificate is valid for ...` | SAN does not match the record | `gateway_dns_name` and the certificate must be the same string |
| `401` on every batch | credential drift between the two Secrets | re-apply `prod-platform`; both Secrets come from one `random_password` |
| agent `CrashLoopBackOff` at startup | Alloy config error, or a component below the stability level | `kubectl logs` names the line and column. Run `make alloy-validate` |
| gateway pods `Pending` | the TLS Secret does not exist yet | cert-manager has not issued: `kubectl get certificate -A` |
| `ImagePullBackOff` | the tag was never mirrored | `make mirror`, then check the version pins match |
| gateway `CrashLoopBackOff` mentioning "stability level" | an experimental component with the gate down | see [ADR 0006](adr/0006-telemetry-agent-selection.md); `alloy.stabilityLevel` |

## Rotating the ingest credential

One `random_password` feeds both clusters, so rotation is one apply:

```bash
cd terraform/envs/prod-platform
terraform taint 'module.gateway.random_password.ingest'
terraform plan -out=tfplan && terraform apply tfplan
```

Both Secrets and both Helm releases update in the same run. There is a brief window where
the agent retries against the new credential; `retry_on_failure` in the agent's exporter
covers it.

## Enabling the LGTM backends

When Section 3 lands, set `lgtm_enabled = true` in `terraform.tfvars` and apply. The
gateway drops the debug sink, gains the three OTLP exporters, and lowers its stability gate
back to generally-available. Nothing on Cluster A changes — the agent has always sent to
the gateway and never to a backend.

## Teardown

```bash
cd terraform
make platform-destroy   # MUST come first
make destroy
```

Reversing these leaves the platform state referencing clusters that no longer exist, and
its providers can no longer configure themselves to clean it up.

## Cost

The internal NLB is the only hourly charge this layer adds on top of the two clusters —
raw VPC peering has none. Against a $50 budget that matters: **tear the platform layer down
between test runs.**
