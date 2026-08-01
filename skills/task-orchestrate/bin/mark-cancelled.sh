#!/usr/bin/env bash
# mark-cancelled.sh — sibling to update-registry-row.sh: the ONE sanctioned way
# for a bash writer to conclude a task should be cancelled/skipped.
#
# Root cause this closes (20260801-inbox-D198/668C, see project.md Shared
# Context "cursor fallback dispatch raced this session's redispatch of the
# same orphan-requeued row"): a writer that decided a task was cancelled wrote
# a raw `status: cancelled` (not a member of update-registry-row.sh's
# VALID_STATUSES) plus an extra unescaped 7th `|`-delimited reason field
# directly into the registry row. update-registry-row.sh correctly refused to
# touch the resulting malformed row (NF!=8), but nothing had stopped the bad
# write from landing in the first place — no bash helper existed for
# "conclude cancelled"; only the dashboard (server.js's stampCancelMarker() /
# approveRegistryTask()) enforced the documented convention, and only for its
# own awaiting_go-approval-cancel path.
#
# Convention enforced here (mirrors server.js's stampCancelMarker exactly, so
# the monitor dashboard's isCancelledTask() detection works identically
# regardless of which writer cancelled the row):
#   - registry `status` column -> `failed` (the enum has no `cancelled` value)
#   - `mode` / `current_phase` columns are left untouched (a cancellation is
#     not a mode or phase change)
#   - task file gets `cancelled_at: <ISO>` + `cancel_reason: <reason>`
#     prepended to its header (stripping any prior cancel markers first —
#     idempotent), creating a minimal file if none exists yet (e.g. a gated
#     task cancelled before it ever ran)
#
# Race guard: refuses (exit 1, no write to project.md OR the task file) when
# the row's CURRENT status is already `complete` — a cancellation must never
# downgrade/clobber a row a concurrent writer already finished. This is
# exactly the regression scenario two near-simultaneous writers can hit: one
# writes a valid `complete` transition (via update-registry-row.sh), the
# other concludes the same row should be cancelled (via this helper) — the
# completion wins, the cancel is rejected with a clear error, and the row
# never lands in an out-of-domain state either way (both writers only ever
# write a VALID enum value through the same NF==8-safe atomic temp+mv
# pattern, so even ordinary last-writer-wins interleaving stays structurally
# sound).
#
# Usage: mark-cancelled.sh <ROOT> <ID> <reason>
set -euo pipefail

die() { echo "mark-cancelled.sh: $*" >&2; exit 1; }

[[ $# -eq 3 ]] || die "usage: <ROOT> <ID> <reason>"

ROOT="$1"; ID="$2"; REASON="$3"

PROJ="$ROOT/.orchestrate/project.md"
TASKS_DIR="$ROOT/.orchestrate/tasks"
TASK_FILE="$TASKS_DIR/${ID}.md"

[[ -f "$PROJ" ]] || die "project.md not found at $PROJ"
[[ -n "$REASON" ]] || die "reason must not be empty"

grep -qE "^\|[[:space:]]*${ID}[[:space:]]*\|" "$PROJ" || die "no registry row found for ID '$ID'"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TMP="$(mktemp "${TMPDIR:-/tmp}/mark-cancelled.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

set +e
awk -F'|' -v OFS='|' -v id="$ID" -v ts="$NOW" '
  /^\|[[:space:]]*[0-9]/ && NF==8 {
    rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
    if (rid==id) {
      found=1
      st=$6; gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
      if (st=="complete") { blocked=1; print; next }
      $6=" failed "; $7=" " ts " "
    }
  }
  { print }
  END { exit(blocked?3:(found?0:2)) }
' "$PROJ" > "$TMP"
AWK_STATUS=$?
set -e

case "$AWK_STATUS" in
  0) : ;;
  2) die "row matched by grep but not updated by awk (unexpected NF!=8?)" ;;
  3) die "refusing to cancel '$ID': row is already 'complete' (a concurrent writer finished it first — this is the expected race-loser rejection, not a bug; the row was left untouched)" ;;
  *) die "unexpected awk exit status $AWK_STATUS" ;;
esac

mv "$TMP" "$PROJ"
trap - EXIT

# Stamp the durable cancellation marker onto the task file. Idempotent: strips
# any prior cancelled_at:/cancel_reason: lines before prepending fresh ones.
mkdir -p "$TASKS_DIR"
SAFE_REASON="$(printf '%s' "$REASON" | tr '\r\n' '  ')"
if [[ -f "$TASK_FILE" ]]; then
  BODY_TMP="$(mktemp "${TMPDIR:-/tmp}/mark-cancelled-body.XXXXXX")"
  grep -vE '^(cancelled_at|cancel_reason):' "$TASK_FILE" > "$BODY_TMP" 2>/dev/null || true
  {
    printf 'cancelled_at: %s\n' "$NOW"
    printf 'cancel_reason: %s\n' "$SAFE_REASON"
    cat "$BODY_TMP"
  } > "${TASK_FILE}.new"
  mv "${TASK_FILE}.new" "$TASK_FILE"
  rm -f "$BODY_TMP"
else
  {
    printf 'id: %s\n' "$ID"
    printf 'status: failed\n'
    printf 'cancelled_at: %s\n' "$NOW"
    printf 'cancel_reason: %s\n' "$SAFE_REASON"
  } > "$TASK_FILE"
fi

echo "mark-cancelled.sh: ${ID} -> failed (cancelled_at: ${NOW})"
