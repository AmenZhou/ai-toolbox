#!/usr/bin/env bash
# requeue-orphaned-running.sh — deterministic bash mirror of the SKILL.md T-4
# "running tasks (orphaned-row check)" rule.
#
# Root cause (investigated by task 20260716-inbox-3C1D): a registry row is
# marked `running` by (at least) two uncoordinated writers — the bash bulk
# pre-mark `mark_pending_tasks_as_running()` in run-job.sh, and the agent
# session's own per-batch "mark running before dispatch" step (SKILL.md T-4)
# — and BOTH mark `running` strictly before the task file is created and the
# `tend-auto — dispatching "<title>" ({ID})` heartbeat line is written. If the
# ensuing agent CLI invocation fails outright (session_limit/timeout/connection
# error/crash) or a sibling stateless tend session races in mid-batch-prep, the
# row is left `running` with no task file and no dispatch line — orphaned.
#
# Previously the ONLY recovery paths were:
#   (a) an LLM T-4 scan during some OTHER agent-dispatched cycle happening to
#       notice the stale row (opportunistic — never fires if nothing else is
#       actionable, since a bare `running` row does not itself trigger
#       NEED_ACTION), or
#   (b) reset_stale_running_tasks's NO_FILE_GRACE_SECS (1800s) bash fallback,
#       which flips the row to `needs_human` (not `pending`), only THEN making
#       it agent-actionable via the ghost-reset heartbeat line, requiring a
#       FURTHER agent cycle to re-queue it to `pending`.
# Both paths take on the order of 30-35 minutes end to end, and (a) firing
# from two overlapping stateless sessions is exactly what produced the
# same-second double "re-queued orphaned running row" log lines observed for
# 20260715-inbox-3D70.
#
# This script closes the gap deterministically, in bash, every cycle: same
# staleness threshold as the LLM rule (300s), same detection criteria (no task
# file AND no dispatch heartbeat line), same corrective action (requeue to
# `pending`) — but it needs no live agent session to fire, and because it is a
# single bash pass under the tend lock, it cannot double-fire the way two
# independent LLM sessions could.
#
# 20260725-inbox-4C3D: the reset target respects the row's `mode` column —
# `mode: auto` rows requeue to `pending` as always, but `mode: gated` rows
# requeue to `awaiting_go` instead. Resetting a gated row straight to `pending`
# would silently drop its human-approval gate: the row could then be swept
# into the very next `tend go auto` auto-execution batch with no human `go`.
#
# 20260731-inbox-00D2: a row that HAS both a task file and a dispatch
# heartbeat line is normally left alone (genuinely in progress). But the
# `[session=<token>]` suffix on that dispatch line embeds the dispatching
# run-job.sh wrapper's own pid (token shape:
# orchestrate_shell_probe_<epoch>_<pid>_<random>, set once per cycle by
# run-job.sh's `SHELL_PROBE_TOKEN`). If a LATER heartbeat line records that
# same pid dying (killed after a timeout, or falling through both the claude
# and cursor runners), the row is not "genuinely in progress" — its owning
# session no longer exists — and the 300s staleness wait before requeue is
# pure unnecessary latency. This pass cross-references dispatch pid against
# later run-job death lines and requeues immediately when a match is found,
# bypassing ORPHAN_STALE_SECS. It reuses the same reset action (pending, or
# awaiting_go for mode: gated) and the same churn-guard counter as the
# no-file/no-dispatch-line path below.
#
# Wired into run-job.sh tend preflight (primary; AFTER repair_registry_rows +
# finalize_completed_tasks, BEFORE reset_stale_running_tasks — so an orphan is
# caught at 300s instead of falling through to the 1800s no-file-grace path)
# and rescue.sh (safety net, same ordering).
set -euo pipefail

ROOT="${1:-$(pwd)}"
PROJ="$ROOT/.orchestrate/project.md"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"

[[ -f "$PROJ" ]] || exit 0

ORPHAN_STALE_SECS="${ORPHAN_STALE_SECS:-300}"

log_orphan() {
  mkdir -p "$(dirname "$HEARTBEAT")" 2>/dev/null || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$HEARTBEAT" 2>/dev/null || true
}

# Share the re-queue counter with run-job.sh / rescue.sh / requeue-unblocked.sh
# so a row that keeps orphaning is parked after CG_THRESHOLD re-processings
# instead of looping forever.
CG_ROOT="$ROOT"
CG_LIB="$ROOT/.orchestrate/bin/churn-guard.sh"
[[ -f "$CG_LIB" ]] && source "$CG_LIB"

trim_ws() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

iso_to_epoch() {
  local ts="$1"
  [[ -z "$ts" ]] && { echo 0; return; }
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || echo 0
}

# reset_running_row <row_id> <mode> <la_epoch> <reason-suffix>
# Shared corrective action for both detection paths below: flip the row
# (pending, or awaiting_go for mode: gated), run it through the shared
# churn-guard counter, and log the outcome. Returns 0 if the row was flipped
# (or parked), 1 if the row did not flip (malformed/raced — caller should not
# treat this as handled).
reset_running_row() {
  local row_id="$1" mode="$2" la_epoch="$3" reason="$4"
  local reset_status="pending"
  [[ "$mode" == "gated" ]] && reset_status="awaiting_go"

  local now_iso tmp rc=0
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  awk -F'|' -v OFS='|' -v id="$row_id" -v ts="$now_iso" -v new_status="$reset_status" '
    /^\|[[:space:]]*[0-9]/ && NF==8 {
      rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
      st=$6;  gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
      if (rid==id && st=="running") { $6=" " new_status " "; $7=" " ts " "; flipped=1 }
    }
    { print }
    END { exit (flipped ? 0 : 2) }
  ' "$PROJ" > "$tmp" || rc=$?

  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"
    log_orphan "requeue-orphaned-running SKIPPED ${row_id}: row did not flip (malformed/raced); awaiting repair_registry_rows"
    return 1
  fi
  mv "$tmp" "$PROJ"

  local parked=0
  if type cg_increment >/dev/null 2>&1; then
    if type cg_increment_unless_transient >/dev/null 2>&1; then
      cg_increment_unless_transient "$row_id" "$la_epoch" >/dev/null 2>&1 || true
    else
      cg_increment "$row_id" >/dev/null 2>&1 || true
    fi
    if cg_park_if_churned "$row_id" 2>/dev/null; then
      parked=1
      log_orphan "churn-guard parked ${row_id} after ${CG_THRESHOLD:-3} re-processings (${reason})"
    fi
  fi
  if [[ "$parked" -ne 1 ]]; then
    if [[ "$reset_status" == "awaiting_go" ]]; then
      log_orphan "tend-auto — re-queued orphaned running row ${row_id} to awaiting_go (mode: gated, ${reason})"
    else
      log_orphan "tend-auto — re-queued orphaned running row ${row_id} (${reason})"
    fi
  fi
  return 0
}

# dead_dispatch_session_pid <row_id> <dispatch_line>
# Extracts the [session=<token>] suffix from the row's most recent dispatch
# heartbeat line and returns the embedded wrapper pid (token shape:
# orchestrate_shell_probe_<epoch>_<pid>_<random>) on stdout. Empty output
# means no correlatable session token (e.g. [session=no-token], or no
# dispatch line at all).
dead_dispatch_session_pid() {
  local dispatch_line="$1"
  [[ -z "$dispatch_line" ]] && return 0
  local token
  token="$(printf '%s' "$dispatch_line" | grep -oE '\[session=[^]]+\]' | tail -1 | sed -E 's/\[session=([^]]+)\]/\1/')" || true
  [[ -z "$token" || "$token" == "no-token" ]] && return 0
  local pid
  pid="$(awk -F'_' '{print $5}' <<< "$token")" || true
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    printf '%s' "$pid"
  fi
  return 0
}

# dispatching_session_died <dispatch_line>
# Returns 0 (found) if a run-job death line for the dispatching session's pid
# appears in the heartbeat AFTER the dispatch line itself — meaning the
# wrapper that dispatched this row's execution has since died (timed out and
# was killed, or both runners failed) with no completion recorded for this
# row. Comparison is by heartbeat LINE ORDER, not timestamp: a fast kill can
# be logged in the same wall-clock second as its dispatch line, so a
# second-granularity ISO timestamp comparison can false-negative on a tie —
# append order in this file is always causally accurate. Echoes the matching
# death line's text (without its line-number prefix) on stdout when found.
dispatching_session_died() {
  local dispatch_line="$1"
  local dpid
  dpid="$(dead_dispatch_session_pid "$dispatch_line")" || true
  [[ -z "$dpid" ]] && return 1

  local dispatch_lineno
  dispatch_lineno="$(grep -nF -- "$dispatch_line" "$HEARTBEAT" 2>/dev/null | tail -1 | cut -d: -f1)" || true
  [[ -z "$dispatch_lineno" ]] && return 1

  local death_match death_lineno death_text
  death_match="$(grep -nE "run-job — .*\[pid=${dpid}\]" "$HEARTBEAT" 2>/dev/null | grep -E "killed|timed out|cursor failed|failed \(exit classification" | tail -1)" || true
  [[ -z "$death_match" ]] && return 1
  death_lineno="${death_match%%:*}"
  death_text="${death_match#*:}"

  if [[ "$death_lineno" =~ ^[0-9]+$ ]] && [[ "$death_lineno" -gt "$dispatch_lineno" ]]; then
    printf '%s' "$death_text"
    return 0
  fi
  return 1
}

requeue_orphaned_running_rows() {
  [[ -f "$PROJ" ]] || return 0
  local now_epoch
  now_epoch="$(date +%s)"

  local row_id mode status last_activity
  while IFS='|' read -r _ row_id _ mode _ status last_activity _; do
    row_id="$(trim_ws "$row_id")"
    mode="$(trim_ws "$mode")"
    status="$(trim_ws "$status")"
    last_activity="$(trim_ws "$last_activity")"
    [[ -z "$row_id" || "$row_id" == "ID" || "$row_id" =~ ^-+$ ]] && continue
    [[ "$status" == "running" ]] || continue

    local task_file="$ROOT/.orchestrate/tasks/${row_id}.md"
    local has_task_file=0
    [[ -f "$task_file" ]] && has_task_file=1

    local dispatch_line=""
    dispatch_line="$(grep -E "tend-auto — dispatching \".*\" \(${row_id}\)" "$HEARTBEAT" 2>/dev/null | tail -1 || true)"

    local la_epoch=0
    if [[ -n "$last_activity" ]]; then
      la_epoch="$(iso_to_epoch "$last_activity")"
    fi

    # Dead-session-pid cross-reference: fires regardless of task-file/
    # dispatch-line presence, bypassing the staleness gate below — a row
    # whose dispatching wrapper has already died is not "genuinely in
    # progress" no matter how fresh last_activity looks.
    if [[ -n "$dispatch_line" ]]; then
      local death_line=""
      if death_line="$(dispatching_session_died "$dispatch_line")"; then
        reset_running_row "$row_id" "$mode" "$la_epoch" \
          "dispatching session died: ${death_line#*] }; detected via dead-session-pid cross-reference" || true
        continue
      fi
    fi

    # Has a task file → genuinely in progress (or already handled elsewhere).
    [[ $has_task_file -eq 1 ]] && continue

    # Has a dispatch heartbeat line for this ID → genuinely in progress; the
    # batch that owns it hasn't reached the task-file-creation step yet.
    [[ -n "$dispatch_line" ]] && continue

    # Staleness gate: only fire once last_activity is old enough that this
    # cannot be a dispatch genuinely still in its mark-running-before-dispatch
    # window within the current cycle.
    local age=$(( now_epoch - la_epoch ))
    [[ $age -lt $ORPHAN_STALE_SECS ]] && continue

    # Gated rows must never be silently re-queued straight to `pending` — that
    # would drop the human-approval gate and let the row get swept into the
    # next `tend go auto` auto-execution batch unattended (20260725-inbox-4C3D).
    reset_running_row "$row_id" "$mode" "$la_epoch" "no task file, no dispatch heartbeat"
  done < <(grep -E '^\|[[:space:]]*[0-9]' "$PROJ" 2>/dev/null || true)
}

requeue_orphaned_running_rows
