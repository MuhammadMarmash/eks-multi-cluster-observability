#!/usr/bin/env bash
# PreToolUse (Bash): hard-deny commands that tear down infrastructure or files.
# These stay available to you interactively — run them yourself with `! <command>`.
set -uo pipefail

cmd=$(jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

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

if printf '%s' "$cmd" | grep -Eq '\bterraform\b[^;&|]*\bdestroy\b'; then
  deny "Blocked by .claude/hooks/block-dangerous-bash.sh: 'terraform destroy' tears down real AWS infrastructure. Ask the user to run it themselves with '! terraform destroy'."
fi

if printf '%s' "$cmd" | grep -Eq '\bterraform\b[^;&|]*\bapply\b[^;&|]*--?auto-approve'; then
  deny "Blocked by .claude/hooks/block-dangerous-bash.sh: 'terraform apply -auto-approve' skips the plan review. Run 'terraform plan' and let the user approve the apply."
fi

if printf '%s' "$cmd" | grep -Eq '\brm\b[^;&|]*(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|--recursive[^;&|]*--force|--force[^;&|]*--recursive)'; then
  deny "Blocked by .claude/hooks/block-dangerous-bash.sh: recursive force-delete is not permitted. Delete specific paths without -rf, or ask the user to run it themselves."
fi

if printf '%s' "$cmd" | grep -Eq '\bgit\b[^;&|]*--no-verify'; then
  deny "Blocked by .claude/hooks/block-dangerous-bash.sh: --no-verify skips the repository's git hooks. Fix whatever the hook is complaining about instead."
fi

exit 0
