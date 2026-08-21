#!/usr/bin/env bash
#
# Render the LGTM Helm values with Terraform and template them against the real
# charts.
#
# This is the LGTM equivalent of scripts/validate-alloy-configs.sh, and it earns
# its keep the same way. A `terraform test` assertion proves the values MAP is
# what we intended; it cannot prove the CHART accepts it. A key that does not
# exist is silently ignored by Helm — no error, no warning, and the default
# stays in force.
#
# Bugs this check has already caught:
#   - mimir-distributed 6.2.0 ships kafka.enabled=true, rendering a Kafka
#     StatefulSet with a 5Gi PVC that nothing uses.
#   - the Loki chart's key is persistence.volumeClaimsEnabled, not
#     persistence.enabled; the latter is accepted and ignored, leaving the PVC.
#
# Charts are pulled from upstream because this runs at development time, not at
# deploy time — ADR 0005 governs what a CLUSTER pulls, not what an engineer
# renders locally.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE="${REPO_ROOT}/terraform/modules/lgtm-backends"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

command -v helm >/dev/null 2>&1 || { echo "helm is required" >&2; exit 1; }

# Chart versions, read from the module's own defaults so this cannot drift.
version_of() {
  sed -n "/variable \"$1\"/,/^}/p" "${MODULE}/variables.tf" \
    | sed -n 's/.*default *= *"\(.*\)"/\1/p' | head -1
}
MIMIR_V="$(version_of mimir_chart_version)"
LOKI_V="$(version_of loki_chart_version)"
TEMPO_V="$(version_of tempo_chart_version)"

cat > "${WORKDIR}/vals.tfvars" <<'EOF'
namespace  = "lgtm"
aws_region = "eu-west-1"
buckets          = { mimir = "check-mimir-000000000000", loki = "check-loki-000000000000", tempo = "check-tempo-000000000000" }
irsa_role_arns   = { mimir = "arn:aws:iam::000000000000:role/mimir", loki = "arn:aws:iam::000000000000:role/loki", tempo = "arn:aws:iam::000000000000:role/tempo" }
chart_repository = "oci://000000000000.dkr.ecr.eu-west-1.amazonaws.com/charts"
image_registry   = "000000000000.dkr.ecr.eu-west-1.amazonaws.com"
EOF

printf '\033[36m==> pulling upstream charts\033[0m\n'
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1
helm pull grafana/mimir-distributed --version "$MIMIR_V" --untar --untardir "$WORKDIR" >/dev/null
helm pull grafana/loki              --version "$LOKI_V"  --untar --untardir "$WORKDIR" >/dev/null
helm pull grafana/tempo-distributed --version "$TEMPO_V" --untar --untardir "$WORKDIR" >/dev/null

( cd "$MODULE" && terraform init -backend=false -input=false >/dev/null 2>&1 )

fail=0
for pair in "mimir:mimir-distributed" "loki:loki" "tempo:tempo-distributed"; do
  component="${pair%%:*}"; chart="${pair##*:}"

  # Terraform renders the values, so this can never drift from what the module
  # actually deploys.
  ( cd "$MODULE" && echo "jsonencode(local.${component}_values)" \
      | terraform console -var-file="${WORKDIR}/vals.tfvars" 2>/dev/null ) \
    | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g' > "${WORKDIR}/${component}.json"

  python3 -c "
import json,yaml,sys
yaml.safe_dump(json.load(open('${WORKDIR}/${component}.json')), open('${WORKDIR}/${component}.yaml','w'))
"

  if ! helm template "$component" "${WORKDIR}/${chart}" \
        -f "${WORKDIR}/${component}.yaml" --namespace lgtm \
        > "${WORKDIR}/${component}-rendered.yaml" 2>"${WORKDIR}/${component}.err"; then
    printf '  \033[31mFAIL\033[0m %s render\n' "$component"
    sed 's/^/       /' "${WORKDIR}/${component}.err" | head -10
    fail=1
    continue
  fi
  printf '  \033[32mok\033[0m   %s renders (chart %s)\n' "$component" "$chart"
done

[ "$fail" -eq 0 ] || exit 1

# The properties that matter, asserted against the RENDERED objects rather than
# against our own values map.
python3 - "$WORKDIR" <<'PY'
import sys, yaml, re
wd = sys.argv[1]
expect_sa = {"mimir": "mimir-sa", "loki": "loki-sa", "tempo": "tempo-sa"}
problems = []
totals = {"pods": 0, "cpu": 0.0, "mem": 0}

def cpu(v):
    if v is None: return 0.0
    v = str(v); return int(v[:-1]) / 1000 if v.endswith("m") else float(v)

def mem(v):
    if v is None: return 0
    m = re.match(r"(\d+)\s*(Mi|Gi)?", str(v))
    if not m: return 0
    return int(m.group(1)) * (1024 if m.group(2) == "Gi" else 1)

for c, want_sa in expect_sa.items():
    docs = [d for d in yaml.safe_load_all(open(f"{wd}/{c}-rendered.yaml")) if isinstance(d, dict)]

    sas = {d["metadata"]["name"]: (d["metadata"].get("annotations") or {})
           for d in docs if d["kind"] == "ServiceAccount"}
    if want_sa not in sas:
        problems.append(f"{c}: no ServiceAccount named {want_sa} (found {sorted(sas)})")
    elif "eks.amazonaws.com/role-arn" not in sas[want_sa]:
        problems.append(f"{c}: {want_sa} carries no eks.amazonaws.com/role-arn annotation")

    for d in docs:
        name = d.get("metadata", {}).get("name", "")
        if "minio" in name.lower():
            problems.append(f"{c}: bundled MinIO object rendered ({name})")
        if d["kind"] == "PersistentVolumeClaim":
            problems.append(f"{c}: standalone PVC rendered ({name})")
        if d["kind"] not in ("Deployment", "StatefulSet"):
            continue
        if d["spec"].get("volumeClaimTemplates"):
            problems.append(f"{c}: {name} still has a volumeClaimTemplate")
        reps = d["spec"].get("replicas", 1) or 1
        totals["pods"] += reps
        for ct in d["spec"]["template"]["spec"]["containers"]:
            r = (ct.get("resources") or {}).get("requests") or {}
            totals["cpu"] += cpu(r.get("cpu")) * reps
            totals["mem"] += mem(r.get("memory")) * reps

for p in problems:
    print(f"  \033[31mFAIL\033[0m {p}")

print(f"\n  footprint: {totals['pods']} pods, "
      f"{totals['cpu']:.2f} vCPU, {totals['mem']/1024:.2f} GiB requested")
# 2 x t3.large allocatable, after kubelet and system reservations.
print(f"  against 2 x t3.large (~3.86 vCPU / ~13.4 GiB allocatable): "
      f"CPU {totals['cpu']/3.86*100:.0f}%, MEM {totals['mem']/1024/13.4*100:.0f}%")

sys.exit(1 if problems else 0)
PY

printf '\033[32mLGTM values ok\033[0m\n'
