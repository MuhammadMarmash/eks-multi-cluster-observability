#!/usr/bin/env bash
# PreToolUse (Bash): hard-deny commands that tear down infrastructure or files.
# These stay available to you interactively — run them yourself with `! <command>`.
#
# Matching is deliberately narrower than "does this string appear anywhere in
# the command", because that also matches PROSE — a heredoc writing docs that
# mention a teardown command, or a commit message describing one. Two filters
# keep the check on actual commands:
#
#   1. Heredoc bodies are stripped before matching, so `cat > f <<'EOF' ... EOF`
#      is judged on the `cat` line alone, not on the document it writes.
#   2. A command must start a statement: at the beginning of a line or after a
#      `;`, `&` or `|`, optionally behind a wrapper such as sudo / env FOO=bar /
#      timeout 300 / nohup. So `echo "run terraform destroy later"` passes while
#      `cd infra && sudo terraform destroy` does not.
set -uo pipefail

cmd=$(jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# Drop heredoc bodies: any line after `<<DELIM` / `<<-'DELIM'` up to the
# closing delimiter is document text, not a command.
read -r -d '' strip_heredocs <<'AWK'
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
in_here {
  if (trim($0) == delim) { in_here = 0 }
  next
}
{
  print
  if (match($0, /<<-?[[:space:]]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/)) {
    d = substr($0, RSTART, RLENGTH)
    sub(/^<<-?[[:space:]]*/, "", d)
    gsub(/['"]/, "", d)
    if (d != "") { delim = d; in_here = 1 }
  }
}
AWK

scanned=$(printf '%s' "$cmd" | awk "$strip_heredocs")
[ -n "$scanned" ] || exit 0

# Wrappers a real invocation may legitimately hide behind.
wrap='(sudo|env|nohup|time|command|timeout|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|[0-9]+[smhd]?)[[:space:]]+'
# Start of a statement: line start, or after a shell separator.
start="(^|[;&|])[[:space:]]*(${wrap})*"

matches() { printf '%s' "$scanned" | grep -Eq "$1"; }

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

if matches "${start}terraform\b[^;&|]*\bdestroy\b"; then
  deny "Blocked by .claude/hooks/block-dangerous-bash.sh: 'terraform destroy' tears down real AWS infrastructure. Ask the user to run it themselves with '! terraform destroy'."
fi

if matches "${start}terraform\b[^;&|]*\bapply\b[^;&|]*--?auto-approve"; then
  deny "Blocked by .claude/hooks/block-dangerous-bash.sh: 'terraform apply -auto-approve' skips the plan review. Run 'terraform plan' and let the user approve the apply."
fi

if matches "${start}rm\b[^;&|]*(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|--recursive[^;&|]*--force|--force[^;&|]*--recursive)"; then
  deny "Blocked by .claude/hooks/block-dangerous-bash.sh: recursive force-delete is not permitted. Delete specific paths without -rf, or ask the user to run it themselves."
fi

if matches "${start}git\b[^;&|]*--no-verify"; then
  deny "Blocked by .claude/hooks/block-dangerous-bash.sh: --no-verify skips the repository's git hooks. Fix whatever the hook is complaining about instead."
fi

exit 0
