#!/usr/bin/env bash
#
# Render every .alloy config template with Terraform and validate it with the
# real Alloy binary.
#
# This is the check that earns its keep. An Alloy config error — a misspelled
# argument, a component below the configured stability level — does not surface
# at terraform plan, at helm template, or even at helm install. It surfaces as a
# CrashLoopBackOff twenty minutes into an apply, on a cluster that costs money
# per hour.
#
# `alloy fmt` checks syntax. `alloy validate` checks the component graph:
# whether each component exists, whether its arguments are real, and whether it
# is permitted at the configured stability level. Both run here.
#
# Requires docker and the Alloy image. Skips with a warning if either is
# missing, so it never blocks a machine that cannot run it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOY_IMAGE="${ALLOY_IMAGE:-grafana/alloy:v1.12.0}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  printf '\033[33mSKIP: docker is unavailable, cannot validate Alloy configs\033[0m\n'
  exit 0
fi

if ! docker image inspect "$ALLOY_IMAGE" >/dev/null 2>&1; then
  printf '\033[36m==> pulling %s\033[0m\n' "$ALLOY_IMAGE"
  docker pull "$ALLOY_IMAGE" >/dev/null
fi

# Terraform renders the template, so this can never drift from what the module
# actually deploys the way a reimplementation of templatefile would.
render() {
  local template="$1" outfile="$2" vars="$3"
  ( cd "$WORKDIR" && terraform init -backend=false -input=false >/dev/null 2>&1 || true )
  printf 'templatefile("%s", %s)' "$template" "$vars" \
    | ( cd "$WORKDIR" && terraform console ) \
    | sed -e '1{/^<<EOT$/d}' -e '${/^EOT$/d}' \
    > "$outfile"
}

validate() {
  local name="$1" file="$2" stability="$3"
  docker run --rm --entrypoint /bin/alloy -v "$(dirname "$file")":/w "$ALLOY_IMAGE" \
    fmt "/w/$(basename "$file")" >/dev/null
  docker run --rm --entrypoint /bin/alloy -v "$(dirname "$file")":/w "$ALLOY_IMAGE" \
    validate --stability.level="$stability" "/w/$(basename "$file")"
  printf '  \033[32mok\033[0m   %s (stability: %s)\n' "$name" "$stability"
  pass=$((pass + 1))
}

GATEWAY_TPL="${REPO_ROOT}/terraform/modules/telemetry-gateway/config.alloy.tftpl"
AGENT_TPL="${REPO_ROOT}/terraform/modules/telemetry-agent/config.alloy.tftpl"

printf '\033[36m==> gateway (Cluster B)\033[0m\n'

# Pre-Section-3: the debug sink is experimental, and the module raises the
# stability gate to match. Validating at generally-available here would be
# validating a configuration the module never produces.
render "$GATEWAY_TPL" "$WORKDIR/gateway-debug.alloy" \
  '{log_level="info",memory_limit="512MiB",tls_cert_path="/etc/alloy/tls/tls.crt",tls_key_path="/etc/alloy/tls/tls.key",lgtm_enabled=false,mimir_endpoint="http://mimir/otlp",loki_endpoint="http://loki/otlp",tempo_endpoint="tempo:4317"}'
validate "debug sink" "$WORKDIR/gateway-debug.alloy" experimental

# With real backends, every component must be generally-available. If this
# fails, an experimental component crept into the production path.
render "$GATEWAY_TPL" "$WORKDIR/gateway-lgtm.alloy" \
  '{log_level="info",memory_limit="512MiB",tls_cert_path="/etc/alloy/tls/tls.crt",tls_key_path="/etc/alloy/tls/tls.key",lgtm_enabled=true,mimir_endpoint="http://mimir/otlp",loki_endpoint="http://loki/otlp",tempo_endpoint="tempo:4317"}'
validate "LGTM exporters" "$WORKDIR/gateway-lgtm.alloy" generally-available

if [ -f "$AGENT_TPL" ]; then
  printf '\033[36m==> agent (Cluster A)\033[0m\n'
  render "$AGENT_TPL" "$WORKDIR/agent.alloy" \
    '{cluster_name="obs-platform-prod-workload",log_level="info",memory_limit="384MiB",scrape_interval="60s",gateway_endpoint="gateway.observability.internal:4317",ca_file_path="/etc/alloy/certs/ca.crt"}'
  validate "collection pipeline" "$WORKDIR/agent.alloy" generally-available
fi

printf '\033[32m%d config(s) validated\033[0m\n' "$pass"
