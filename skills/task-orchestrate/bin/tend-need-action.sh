#!/usr/bin/env bash
# tend-need-action.sh — T-1 pre-flight scan (read-only; no lock)
# Exit 0 when idle (NEED_ACTION=0), exit 1 when action required.
set -euo pipefail

ROOT="${1:-.}"
PROJ="$ROOT/.orchestrate/project.md"

count_status() {
  local st="$1"
  [[ -f "$PROJ" ]] || { echo 0; return; }
  # grep returns 1 on no match — must not abort under set -e
  awk -F'|' -v st="$st" '
    /^\|/ && $2 !~ /^[[:space:]]*ID[[:space:]]*$/ && $2 !~ /^-+$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6)
      if ($6 == st) n++
    }
    END { print n + 0 }
  ' "$PROJ"
}

registry_actionable=0
for st in pending awaiting_go awaiting_critic needs_human running; do
  n="$(count_status "$st")"
  registry_actionable=$(( registry_actionable + n ))
done

inbox_count=0
for f in "$ROOT/.orchestrate/inbox"/*.md "$ROOT/.orchestrate/inbox/gated"/*.md; do
  [[ -f "$f" ]] || continue
  grep -qE '^deferred_at:' "$f" 2>/dev/null && continue
  inbox_count=$(( inbox_count + 1 ))
done

NEED_ACTION=0
[[ "$registry_actionable" -gt 0 ]] && NEED_ACTION=1
[[ "$inbox_count" -gt 0 ]] && NEED_ACTION=1

echo "NEED_ACTION=$NEED_ACTION"
echo "REGISTRY_ACTIONABLE=$registry_actionable"
echo "INBOX_ACTIVE=$inbox_count"
exit "$NEED_ACTION"
