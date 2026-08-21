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
  if grep -qE -- "$pattern" "$OUT"; then
    printf '  ok   %s\n' "$description"
  else
    printf '  FAIL %s (no match for /%s/)\n' "$description" "$pattern" >&2
    exit 1
  fi
}

refute() {
  local description="$1" pattern="$2"
  if grep -qE -- "$pattern" "$OUT"; then
    printf '  FAIL %s (unexpected match for /%s/)\n' "$description" "$pattern" >&2
    exit 1
  fi
  printf '  ok   %s\n' "$description"
}

check  "bootstrap issuer is selfSigned"        'selfSigned: \{\}'
check  "CA certificate is marked isCA"         'isCA: true'
check  "CA issuer reads the CA secret"         '^  ca:$'
check  "gateway cert carries the exact SAN"    '- gateway\.observability\.internal'
check  "gateway cert lands in its namespace"   'namespace: telemetry'
check  "CA material stays in cert-manager ns"  'namespace: cert-manager'
check  "gateway cert renews before expiry"     'renewBefore:'
check  "server auth usage is requested"        '- server auth'
refute "no Secret is templated by this chart"  'kind: Secret'

printf 'chart ok\n'
