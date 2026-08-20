#!/usr/bin/env bash
# PreToolUse (Write|Edit): refuse to write credential material into files git tracks.
# Gitignored paths (terraform.tfvars, *.pem, .env) are exempt — that is where
# real secrets are supposed to live.
set -uo pipefail

payload=$(cat)
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')
body=$(printf '%s' "$payload" |
  jq -r '[.tool_input.content, .tool_input.new_string] | map(select(. != null)) | join("\n")')

[ -n "$body" ] || exit 0

# This script and its siblings contain the detection patterns themselves.
case "$file" in
  */.claude/hooks/* | .claude/hooks/*) exit 0 ;;
esac

# Already gitignored? Then it is never going to be committed.
if [ -n "$file" ] && git check-ignore -q -- "$file" 2>/dev/null; then
  exit 0
fi

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

if printf '%s' "$body" | grep -Eq '(AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}'; then
  deny "Blocked by .claude/hooks/secret-guard.sh: this write contains something shaped like an AWS access key ID, and '$file' is not gitignored. Put it in terraform.tfvars or an env var instead."
fi

if printf '%s' "$body" | grep -Eq '(aws_secret_access_key|AWS_SECRET_ACCESS_KEY)[[:space:]]*[=:][[:space:]]*.?[A-Za-z0-9/+=]{40}'; then
  deny "Blocked by .claude/hooks/secret-guard.sh: this write contains something shaped like an AWS secret access key, and '$file' is not gitignored. Reference a variable instead of inlining it."
fi

if printf '%s' "$body" | grep -Eq -- '-----BEGIN( [A-Z]+)* PRIVATE KEY-----'; then
  deny "Blocked by .claude/hooks/secret-guard.sh: this write contains a private key block, and '$file' is not gitignored. Private keys belong in a *.pem file, which .gitignore already excludes."
fi

exit 0
