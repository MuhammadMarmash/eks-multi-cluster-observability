#!/usr/bin/env bash
# PostToolUse (Write|Edit): canonicalise any Terraform file Claude just wrote,
# so formatting never shows up as diff noise in a review.
set -uo pipefail

file=$(jq -r '.tool_response.filePath // .tool_input.file_path // empty')

case "$file" in
  *.tf | *.tfvars | *.tftest.hcl) ;;
  *) exit 0 ;;
esac

[ -f "$file" ] || exit 0

terraform fmt "$file" >/dev/null 2>&1 || true
