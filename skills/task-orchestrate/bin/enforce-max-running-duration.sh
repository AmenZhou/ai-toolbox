#!/usr/bin/env bash
# enforce-max-running-duration.sh — hard cap on total dispatch-to-now runtime for
# `running` registry rows. Planned by task 20260731-inbox-8684 (ORCH-2-INV); see
# reports/orchestrate/orch-2-inv_plan.md for the full design + rationale.
#
# What this adds (genuinely new — see the plan's §1 comparison table): any row
# that has been `running` for more than MAX_RUNNING_SECS of real wall-clock time
# SINCE IT WAS DISPATCHED is flipped to `needs_human` — even if it is actively
# making progress. This is a hard elapsed-runtime cap, deliberately NOT conditioned
# on liveness/activity (user-confirmed). It fires on exactly the rows that
# reset_stale_running_tasks's 19D7 mtime-freshness guard protects.
#
# Clock source (plan §2): the ISO-8601 timestamp PREFIX of the row's MOST RECENT
# `tend-auto — dispatching "<title>" (<ID>)` heartbeat line — NOT last_activity
# (which is overwritten at every phase checkpoint and is the documented
# last_activity-staleness bug class). Most-recent (tail -1), because each
# re-dispatch is a fresh execution attempt; an earlier terminated attempt's elapsed
# time must not count against the current run (the "keeps re-dispatching" case is
# owned by the churn guard, not this cap).
#
# Fail-safe (plan §3): if no dispatch line for the ID is resolvable (heartbeat
# hand-edited, or the row was dispatched by an interactive non-run-job.sh session
# that never wrote a dispatch line), treat it as "cannot determine dispatch time"
# and DO NOT flip. heartbeat.log is append-only (never rotated/truncated), so a row
# still `running` normally has its dispatch line present.
#
# Mode (plan §6): `mode: gated` is treated the SAME as `mode: auto` → `needs_human`,
# matching reset_stale_running_tasks's precedent. The orphan-requeue script sends
# gated rows to `awaiting_go` instead of `pending` because IT resets to a
# re-executable state; this cap resets to `needs_human`, which is never
# auto-dispatched by any tend mode, so there is no human-approval gate to drop.
#
# Churn guard is intentionally NOT invoked (plan §6): this cap fires on
# genuinely-active work and lands it in a human-gated terminal state with no
# autonomous re-dispatch loop, so bumping the poison-park counter would file
# spurious investigate-churn tickets against legitimately long-running tasks.
#
# No-double-fire (plan §5): wired into run-job.sh's tend preflight AFTER
# requeue_orphaned_running and BEFORE reset_stale_running_tasks. All three
# mechanisms share the `status == running` precondition and flip sequentially under
# the single tend lock, so whichever fires first removes the row from the others'
# consideration — at most one flip per row per cycle, no shared guard file needed.
set -euo pipefail

ROOT="${1:-$(pwd)}"
PROJ="$ROOT/.orchestrate/project.md"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"

[[ -f "$PROJ" ]] || exit 0

# 10-minute hard cap. Deliberately a NEW, distinctly-named constant rather than
# reusing STALE_RUNNING_SECS (both equal 600 today) so the ghost-reset staleness
# window and this elapsed-runtime cap can be tuned independently later without
# ambiguity about which one changed.
MAX_RUNNING_SECS="${MAX_RUNNING_SECS:-600}"

log_cap() {
  mkdir -p "$(dirname "$HEARTBEAT")" 2>/dev/null || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$HEARTBEAT" 2>/dev/null || true
}

trim_ws() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

iso_to_epoch() {
  local ts="$1"
  [[ -z "$ts" ]] && { echo 0; return; }
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || echo 0
}

# most_recent_dispatch_ts <row_id>
# Echoes the ISO timestamp prefix of the row's most-recent dispatch heartbeat
# line, or empty if there is none (fail-safe caller must then skip the row).
most_recent_dispatch_ts() {
  local row_id="$1"
  [[ -f "$HEARTBEAT" ]] || return 0
  local line
  line="$(grep -E "tend-auto — dispatching \".*\" \(${row_id}\)" "$HEARTBEAT" 2>/dev/null | tail -1 || true)"
  [[ -z "$line" ]] && return 0
  # Strip the leading "[<ISO>] " — the first bracketed field is always the
  # log_heartbeat() timestamp prefix.
  printf '%s' "$line" | sed -E 's/^\[([^]]+)\].*/\1/'
}

# flip_row_needs_human <row_id> — atomic temp+mv flip of status $6 running→
# needs_human (+ last_activity $7), NF==8-guarded with phantom-column self-heal.
# Returns 0 if the row flipped, 1 if it did not (malformed/raced).
flip_row_needs_human() {
  local row_id="$1"
  local now_iso tmp rc=0
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  awk -F'|' -v OFS='|' -v id="$row_id" -v ts="$now_iso" '
    /^\|[[:space:]]*[0-9]/ && NF>=8 {
      rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
      st=$6;  gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
      if (rid==id && st=="running") {
        $6=" needs_human "; $7=" " ts " "
        if (NF>8) { NF=8; $8="" }
        flipped=1
      }
    }
    { print }
    END { exit (flipped ? 0 : 2) }
  ' "$PROJ" > "$tmp" || rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$PROJ"
  return 0
}

# inject_hint <row_id> <hint> — mirror reset_stale_running_tasks: prepend a
# human_resolution hint under the first INCOMPLETE phase block only (best-effort;
# a missing task file or an all-complete file is simply skipped).
inject_hint() {
  local row_id="$1" hint="$2"
  local task_file="$ROOT/.orchestrate/tasks/${row_id}.md"
  [[ -f "$task_file" ]] || return 0
  local target
  target="$(awk '
    /^### Phase/ { hdr=NR; waiting=1; next }
    waiting && /^status:/ { waiting=0; if ($0 !~ /✓ complete/) { print hdr; exit } }
  ' "$task_file")"
  [[ -z "$target" ]] && return 0
  local tf_tmp
  tf_tmp="$(mktemp "${TMPDIR:-/tmp}/task-md.XXXXXX")"
  awk -v n="$target" -v hint="$hint" '{ print } NR==n { print "human_resolution: " hint }' \
    "$task_file" > "$tf_tmp" && mv "$tf_tmp" "$task_file"
}

enforce_cap() {
  local now_epoch
  now_epoch="$(date +%s)"

  local row_id status
  while IFS='|' read -r _ row_id _ _ _ status _ _; do
    row_id="$(trim_ws "$row_id")"
    status="$(trim_ws "$status")"
    [[ -z "$row_id" || "$row_id" == "ID" || "$row_id" =~ ^-+$ ]] && continue
    [[ "$status" == "running" ]] || continue

    # Clock source: most-recent dispatch line's ISO prefix. No line → fail-safe skip.
    local dispatch_ts dispatch_epoch age
    dispatch_ts="$(most_recent_dispatch_ts "$row_id")"
    [[ -z "$dispatch_ts" ]] && continue
    dispatch_epoch="$(iso_to_epoch "$dispatch_ts")"
    [[ "$dispatch_epoch" -eq 0 ]] && continue   # unparseable timestamp → fail-safe skip
    age=$(( now_epoch - dispatch_epoch ))
    [[ $age -lt $MAX_RUNNING_SECS ]] && continue

    if flip_row_needs_human "$row_id"; then
      inject_hint "$row_id" \
        "Auto-paused by max-runtime-cap: dispatched ${age}s ago, exceeded the 10-minute hard cap (MAX_RUNNING_SECS=${MAX_RUNNING_SECS}s). Verify the work, then re-run via unblock-task."
      log_cap "run-job — max-runtime-cap ${row_id}: running→needs_human (dispatched ${age}s ago, exceeded MAX_RUNNING_SECS=${MAX_RUNNING_SECS}s hard cap)"
    else
      log_cap "run-job — max-runtime-cap SKIPPED ${row_id}: row did not flip (malformed/raced); awaiting repair_registry_rows"
    fi
  done < <(grep -E '^\|[[:space:]]*[0-9]' "$PROJ" 2>/dev/null || true)
}

enforce_cap
