#!/usr/bin/env bash
# requeue-unblocked.sh — auto-requeue needs_human rows when to_clear / requeue signals are satisfied
# Usage: requeue-unblocked.sh <project_root>
# Logs requeues to stdout (caller appends to heartbeat.log).
set -euo pipefail

ROOT="${1:?usage: requeue-unblocked.sh <root>}"
PROJ="$ROOT/.orchestrate/project.md"
TASKS="$ROOT/.orchestrate/tasks"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"

[[ -f "$PROJ" ]] || exit 0

# Churn guard: share the re-queue counter with run-job.sh / rescue.sh so a task
# re-queued 3× from ANY site is parked rather than churning. CG_ROOT pins it here.
CG_ROOT="$ROOT"
if [[ -f "$ROOT/.orchestrate/bin/churn-guard.sh" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT/.orchestrate/bin/churn-guard.sh"
fi

registry_row() {
  local id="$1" field="$2"  # field: status|mode
  awk -F'|' -v id="$id" -v want="$field" '
    $0 ~ "\\| " id " \\|" {
      if (want == "status") { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6); print $6 }
      if (want == "mode")   { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4 }
      exit
    }
  ' "$PROJ"
}

set_pending() {
  local id="$1" reason="$2" since_epoch="${3:-0}" mode="${4:-}" skip_count="${5:-0}"
  # Churn guard: a re-queue (needs_human → pending) is a re-processing. Bump the
  # shared counter; if ${id} has now churned ${CG_THRESHOLD:-3}× without
  # converging, park it (needs_human + bypass markers) + file an investigation job
  # INSTEAD of re-queueing, so a poison task does not loop forever.
  #
  # Use cg_increment_unless_transient (not raw cg_increment) so a requeue driven
  # by run-job.sh's own auto-injected "Auto-reset: task stuck in running ..."
  # human_resolution line is classified the SAME way the ghost-reset step
  # already classified it. Without this, a shell_incapable/transient ghost-reset
  # — correctly skipped (not counted) at reset time by run-job.sh's
  # cg_increment_unless_transient call — got counted anyway the moment this
  # requeue leg picked up that injected line and unconditionally cg_increment'd,
  # double-penalizing dispatch-starvation cycles that never reached any real
  # phase work (root cause of the 20260729-inbox-2408/C94E false churn park —
  # 3 consecutive shell_incapable cycles, each correctly "not counted" at
  # ghost-reset, still parked the task via this leg's blind increment).
  #
  # skip_count (SHELLPROBE-CHURN-2, 20260731-inbox-5632/B560): a DIFFERENT
  # double-count than the one above. That fix aligned classification between
  # the ghost-reset leg and this requeue leg for transient/shell_incapable
  # resets. But for a GENUINE (non-transient) zero-progress ghost-reset — the
  # task was dispatched, its session died mid-batch before any subagent
  # checkpoint, and the row never completed a single phase — BOTH legs still
  # increment: once when the ghost-reset (running→needs_human) fires, and AGAIN
  # here when first-pass-auto-resolve's C5 rule (or an equivalent zero-progress
  # session-death marker) injects a human_resolution and this leg clears it back
  # to pending. That is the SAME failed dispatch attempt counted twice, so a
  # task hits CG_THRESHOLD after only ~1.5 real dispatch cycles instead of 3.
  # The caller sets skip_count=1 when it has already determined (via
  # is_zero_progress_session_death_requeue) that this pending-flip is merely
  # clearing a zero-progress ghost episode the reset leg already counted — the
  # row still advances to pending/awaiting_go below, only the SECOND increment
  # is suppressed. A requeue driven by a genuine NEW human decision (mode:gated
  # unblock, a person's own human_resolution) always has skip_count=0 and keeps
  # counting exactly as before — unweakened.
  if [[ "$skip_count" != "1" ]]; then
    if type cg_increment_unless_transient >/dev/null 2>&1; then
      cg_increment_unless_transient "$id" "$since_epoch" >/dev/null 2>&1 || true
    elif type cg_increment >/dev/null 2>&1; then
      cg_increment "$id" >/dev/null 2>&1 || true
    fi
  fi
  if type cg_park_if_churned >/dev/null 2>&1 && cg_park_if_churned "$id" 2>/dev/null; then
    local pnow line
    pnow="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    line="[${pnow}] tend-auto — churn-guard parked ${id} after ${CG_THRESHOLD:-3} re-queues (requeue-unblocked path); not re-queued"
    echo "$line" >>"$HEARTBEAT"
    echo "$line"
    return 0
  fi
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  # Gated rows must never be silently re-queued straight to `pending` — that
  # would drop the human-approval gate and let the row get swept into the next
  # `tend go auto` auto-execution batch unattended (20260725-inbox-4C3D, the
  # same invariant requeue-orphaned-running.sh already enforces for its own
  # reset path). `mode: auto` rows keep flipping to `pending`; `mode: gated`
  # rows flip to `awaiting_go` instead — mirrors
  # requeue-orphaned-running.sh's reset_status pattern verbatim.
  local reset_status="pending"
  [[ "$mode" == "gated" ]] && reset_status="awaiting_go"
  awk -F'|' -v OFS='|' -v id="$id" -v now="$now" -v new_status="$reset_status" '
    $0 ~ "\\| " id " \\|" {
      for (i=1; i<=NF; i++) {
        f = $i; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f)
        if (f == "needs_human") $i = " " new_status " "
      }
      # Registry-write rule (Shared Context 2026-06-27): stamp last_activity in $7,
      # NEVER $8. Writing $8 appended a phantom field PAST the trailing pipe (NF==8
      # with a non-empty $8, no trailing pipe) — the corruption signature that
      # defeats reset_stale_running_tasks. Self-heal any phantom column in the same
      # pass: keep $7, force NF=8 with an EMPTY trailing $8 so the trailing pipe is
      # restored. No-op shape change on already-valid rows.
      if (NF >= 7) { $7 = " " now " " }
      if (NF > 8) { NF = 8 }
      $8 = ""
    }
    { print }
  ' "$PROJ" > "$tmp" && mv "$tmp" "$PROJ"
  # Clear the bypass marker so the parked task is re-evaluated on the next cycle.
  local tf="$TASKS/${id}.md"
  if [[ -f "$tf" ]] && grep -qE '^(bypassed_at|bypass_reason):' "$tf" 2>/dev/null; then
    local tftmp
    tftmp="$(mktemp "${TMPDIR:-/tmp}/taskfile.XXXXXX")"
    grep -vE '^(bypassed_at|bypass_reason):' "$tf" > "$tftmp" && mv "$tftmp" "$tf"
  fi
  local line="[${now}] tend-auto — requeue-unblocked ${id}: ${reason}"
  echo "$line" >>"$HEARTBEAT"
  echo "$line"
}

closure_in_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -qE '\*\*(Closed|Status):\*\*.*(✅|Closed|CONFIRMED)' "$f" 2>/dev/null || \
    grep -qE '^[|][[:space:]]*\*\*Date confirmed\*\*' "$f" 2>/dev/null
}

# is_zero_progress_session_death_requeue <task_file> — true (0) when the
# pending human_resolution on <task_file> is an auto-injected marker saying
# the row never executed a single phase because ITS OWN dispatching session
# died (as opposed to a human/agent supplying genuinely new guidance to clear
# a real blocker). Two conditions, BOTH required:
#   (1) the task has declared phases (total_phases >= 1) but has completed
#       NONE of them (zero `✓ complete` markers anywhere in the file) — i.e.
#       this row has never once finished a dispatch attempt.
#   (2) human_resolution matches a known zero-progress/session-death phrasing
#       (first-pass-auto-resolve's C5 rule and run-job.sh/rescue.sh's own
#       "Auto-reset: task stuck in running ..." marker both use this
#       language) rather than a substantively new human decision.
#
# SHELLPROBE-CHURN-2 (20260731-inbox-5632/B560): when both hold, the ghost-
# reset leg (rescue.sh / run-job.sh's reset_stale_running_tasks) already
# cg_increment'd for this exact failed attempt the moment it flipped
# running→needs_human. This requeue leg clearing the SAME episode back to
# pending is not a distinct new re-processing — it is the back half of the
# episode already counted — so the caller uses this to set set_pending's
# skip_count and avoid a double bump. A requeue whose human_resolution
# reflects a genuine new decision (mode:gated unblock, a person's own note)
# does NOT match (2) and is unaffected — still counted exactly as before.
is_zero_progress_session_death_requeue() {
  local tf="$1" total complete
  [[ -f "$tf" ]] || return 1
  total="$(grep -oE '^total_phases:[[:space:]]*[0-9]+' "$tf" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
  [[ -n "$total" && "$total" -ge 1 ]] || return 1
  complete="$(grep -c '✓ complete' "$tf" 2>/dev/null || true)"
  complete="${complete:-0}"
  [[ "$complete" -eq 0 ]] || return 1
  grep -qiE 'never actually executed|zero-progress session-death|session died mid-batch|tend session likely died|task stuck in running' "$tf" 2>/dev/null
}

# dispatch_since_epoch <task_id> <fallback_epoch> — epoch of the most recent
# "tend-auto — dispatching ... (<task_id>)" heartbeat line at/before
# fallback_epoch, or fallback_epoch itself if none is found.
#
# Root cause (SHELLPROBE-CHURN-1, found investigating 20260731-inbox-273D's
# false churn-park): the row's `last_activity` at the moment this loop reads
# it is the timestamp run-job.sh's reset_stale_running_tasks JUST WROTE when
# it flipped running→needs_human — i.e. the END of the stale window, not the
# START. run-job.sh's own cg_increment_unless_transient call correctly uses
# the row's PRE-reset last_activity (captured before the mutation) as
# since_epoch, so its shell-incapable heartbeat scan (`ts >= since`) still
# covers the "no shell capability; deferred" line that occurred DURING the
# dispatch cycle, before the reset. This loop instead re-read last_activity
# AFTER that same mutation, so since_epoch ended up later than the deferred
# line's own timestamp — the `ts >= since` scan in
# cg__heartbeat_shell_incapable_since silently failed to find it, the reset
# was misclassified as a real (non-shell_incapable) churn, and
# cg_increment_unless_transient fell through to a genuine, silent cg_increment.
# Three such misclassified cycles (each individually logged "not counted" by
# run-job.sh's own check, but silently counted a second time here) parked a
# perfectly healthy task. Fix: anchor since_epoch to the dispatch line itself,
# which — like run-job.sh's la_epoch — necessarily precedes any
# shell-incapable evidence from that same dispatch cycle.
dispatch_since_epoch() {
  local id="$1" fallback="$2" hb line ts epoch best=0
  hb="$HEARTBEAT"
  [[ -f "$hb" ]] || { echo "$fallback"; return; }
  while IFS= read -r line; do
    ts="$(printf '%s' "$line" | grep -oE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]' | tr -d '[]')"
    [[ -n "$ts" ]] || continue
    epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || echo 0)"
    [[ "$epoch" -gt 0 && "$epoch" -le "$fallback" && "$epoch" -gt "$best" ]] && best="$epoch"
  done < <(grep -F "(${id})" "$hb" 2>/dev/null | grep -E 'tend-auto — dispatching ')
  if [[ "$best" -gt 0 ]]; then
    echo "$best"
  else
    echo "$fallback"
  fi
}

requeue_count=0

while IFS='|' read -r _ task_id _ mode _ status last_activity _; do
  task_id="${task_id// /}"
  mode="${mode// /}"
  status="${status// /}"
  last_activity="$(printf '%s' "$last_activity" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [[ "$status" == "needs_human" ]] || continue
  [[ -z "$task_id" || "$task_id" == "ID" ]] && continue

  tf="$TASKS/${task_id}.md"
  [[ -f "$tf" ]] || continue

  # since_epoch for cg_increment_unless_transient's shell_incapable/transient
  # window check. Anchored to the dispatch line (dispatch_since_epoch), not
  # the row's raw last_activity — last_activity by this point already holds
  # the POST-reset timestamp (the moment run-job.sh flipped running→
  # needs_human), which is later than any shell-incapable evidence from the
  # dispatch cycle that caused the reset. See dispatch_since_epoch's comment
  # for the full root-cause (SHELLPROBE-CHURN-1).
  since_epoch=0
  if [[ -n "$last_activity" ]]; then
    since_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$last_activity" +%s 2>/dev/null || echo 0)"
    if [[ "$since_epoch" -gt 0 ]]; then
      since_epoch="$(dispatch_since_epoch "$task_id" "$since_epoch")"
    fi
  fi

  # Skip EXTERNAL blockers unless an explicit requeue signal is satisfied
  if grep -qE '^blocked_on:[[:space:]]*EXTERNAL' "$tf" 2>/dev/null; then
    if ! grep -qE '^requeue_when_exists:' "$tf" 2>/dev/null; then
      continue
    fi
  fi

  # Explicit requeue_when_exists: <path>
  if grep -qE '^requeue_when_exists:' "$tf" 2>/dev/null; then
    ref="$(grep -E '^requeue_when_exists:' "$tf" | head -1 | sed 's/^requeue_when_exists:[[:space:]]*//')"
    ref="${ref/#\~/$HOME}"
    if closure_in_file "$ref"; then
      set_pending "$task_id" "requeue_when_exists satisfied ($ref)" "$since_epoch" "$mode"
      requeue_count=$(( requeue_count + 1 ))
      continue
    fi
  fi

  # Structured to_clear references a decision file — check for filled decision table
  if grep -qE '^to_clear:' "$tf" 2>/dev/null || grep -qE '^## to_clear' "$tf" 2>/dev/null; then
  while IFS= read -r ref; do
    ref="${ref/#\~/$HOME}"
    if closure_in_file "$ref"; then
      set_pending "$task_id" "to_clear signal satisfied ($ref)" "$since_epoch" "$mode"
      requeue_count=$(( requeue_count + 1 ))
      break
    fi
  done < <(grep -oE '[~/][^ )`]+launch_target_decision\.md' "$tf" 2>/dev/null || \
           grep -oE 'reports/phase3/[a-zA-Z0-9_./-]+\.md' "$tf" 2>/dev/null || true)
  fi

  # Human injected resolution that is NOT a BLOCKED marker → requeue
  if grep -qE '^human_resolution:' "$tf" && \
     ! grep -qE '^human_resolution:.*BLOCKED ON HUMAN' "$tf"; then
    # SHELLPROBE-CHURN-2: a zero-progress ghost-reset episode (this row never
    # completed a single phase, and its human_resolution is the auto-injected
    # "session died"/"never actually executed" marker) was already counted by
    # the ghost-reset leg that produced this human_resolution — skip_count=1
    # here avoids re-counting the SAME episode. See
    # is_zero_progress_session_death_requeue's header for the full root-cause.
    skip_count=0
    is_zero_progress_session_death_requeue "$tf" && skip_count=1
    set_pending "$task_id" "human_resolution injected (non-blocked)" "$since_epoch" "$mode" "$skip_count"
    requeue_count=$(( requeue_count + 1 ))
  fi

done < <(grep -E '^\|[[:space:]]*[0-9]' "$PROJ" 2>/dev/null || true)

echo "REQUEUED=$requeue_count"
exit 0
