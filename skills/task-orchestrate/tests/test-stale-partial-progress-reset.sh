#!/usr/bin/env bash
# test-stale-partial-progress-reset.sh — regression for task 20260717-inbox-527A.
#
# Background: reset_stale_running_tasks() (run-job.sh) and its rescue.sh mirror
# both had a ghost check of the form:
#   if [[ -f "$task_file" ]] && grep -q '✓ complete' "$task_file"; then continue; fi
# ANY `✓ complete` phase marker anywhere in the file — even just phase 1 of a
# 5-phase task — permanently protected the row from ghost-reset, forever,
# regardless of how stale the file's mtime got. A `running` task whose
# dispatching session died right after finishing phase N-1 of N could therefore
# never be ghost-reset: the grep always matched. This is exactly what happened
# to task 20260716-inbox-3C1D, whose dispatching session died after completing
# Phases 1-2 of 3, leaving the registry row `running` for ~25 hours.
#
# Fix asserted here: the ghost check now counts phase progress instead of doing
# a bare presence grep. A task file where complete_count >= total_phases (fully
# done) is still an unconditional skip — that is finalize-completed-tasks.sh's
# job, not this reaper's. A PARTIALLY complete file (some but not all phases
# done) is no longer auto-protected: it now falls through to the same 19D7
# mtime-freshness guard that already governs zero-progress files. A stale mtime
# past STALE_RUNNING_SECS → reset to needs_human (not silently re-queued to
# pending). A fresh mtime → still left running (a live session is genuinely
# mid-phase). Covers both run-job.sh's reset_stale_running_tasks() and
# rescue.sh's inline mirror of the same logic.
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
RUNJOB="${RUNJOB:-$PROJECT_ROOT/bin/run-job.sh}"
RESCUE="${RESCUE:-$PROJECT_ROOT/bin/rescue.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

OLD_TS="$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"

TASK_ID="20260717-tst"

# N-1-of-N-complete task file body: 3 total phases, phases 1-2 done, phase 3 stalled.
PARTIAL_BODY="total_phases: 3
### Phase 1
status: ✓ complete
### Phase 2
status: ✓ complete
### Phase 3
status: pending"

# All-phases-complete task file body: 3 of 3 done.
FULL_BODY="total_phases: 3
### Phase 1
status: ✓ complete
### Phase 2
status: ✓ complete
### Phase 3
status: ✓ complete"

# ── run-job.sh: reset_stale_running_tasks() ─────────────────────────────────

# run_reset <registry-row> <task-file-body> [task-file-mtime-min-ago]
# Builds a mock control plane, sources reset_stale_running_tasks() out of
# run-job.sh (same extraction technique as test-ghost-reset-stale-running.sh),
# runs it, and echoes: <final-status>|<count-of-ghost-reset-heartbeat-lines>
run_reset() {
  local row="$1"; local task_file_body="$2"; local mtime_min="${3:-}"
  local TMP; TMP="$(mktemp -d)"
  mkdir -p "$TMP/.orchestrate/tasks" "$TMP/.orchestrate/logs"
  {
    echo "# Orchestrate"
    echo "## Task Registry"
    echo "| ID | summary | mode | current_phase | status | last_activity |"
    echo "|----|---------|------|---------------|--------|---------------|"
    echo "$row"
  } > "$TMP/.orchestrate/project.md"
  printf '%s\n' "$task_file_body" > "$TMP/.orchestrate/tasks/${TASK_ID}.md"
  if [[ -n "$mtime_min" ]]; then
    local bt
    bt="$(date -v-"${mtime_min}"M +%Y%m%d%H%M 2>/dev/null || date -d "${mtime_min} minutes ago" +%Y%m%d%H%M)"
    touch -t "$bt" "$TMP/.orchestrate/tasks/${TASK_ID}.md"
  fi
  (
    ROOT="$TMP"
    log_heartbeat() { echo "$*" >> "$ROOT/.orchestrate/logs/heartbeat.log"; }
    eval "$(awk '/^STALE_RUNNING_SECS=/{p=1} p{print} p&&/^reset_stale_running_tasks\(\) \{/{f=1} f&&/^\}/{exit}' "$RUNJOB")"
    reset_stale_running_tasks
  )
  local status hb
  status="$(grep "$TASK_ID" "$TMP/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
  # NOTE: `grep -c PATTERN FILE` prints "0" to stdout AND exits 1 when FILE exists
  # but has zero matching lines — so a naive `grep -c ... || echo 0` fallback
  # double-counts (both the "0" from grep and the "0" from echo land in the
  # command substitution). Suppress the fallback branch's own output instead.
  hb="$(grep -c "ghost-reset ${TASK_ID}: running→needs_human" "$TMP/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
  hb="${hb:-0}"
  echo "${status}|${hb}"
  rm -rf "$TMP"
}

echo ""
echo "── stale partial-progress ghost-reset (527A) — run-job.sh ───"

[[ -f "$RUNJOB" ]] && ok "run-job.sh present" || fail "run-job.sh missing at $RUNJOB"

echo ""
echo "1. N-1 of N phases complete + STALE mtime → reset to needs_human"
r="$(run_reset "| ${TASK_ID} | dispatching session died mid-run | auto | 3 | running | $OLD_TS |" "$PARTIAL_BODY" 20)"
[[ "${r%%|*}" == "needs_human" ]] && ok "partial-progress + stale mtime reset to needs_human" || fail "status='${r%%|*}' (expected needs_human)"
[[ "$(echo "$r" | cut -d'|' -f2)" -ge 1 ]] && ok "ghost-reset heartbeat written" || fail "no ghost-reset heartbeat for stale partial-progress row"

echo ""
echo "2. N-1 of N phases complete + FRESH mtime → left running (live agent)"
r="$(run_reset "| ${TASK_ID} | still actively writing phase 3 | auto | 3 | running | $OLD_TS |" "$PARTIAL_BODY" 0)"
[[ "${r%%|*}" == "running" ]] && ok "partial-progress + fresh mtime left running" || fail "status='${r%%|*}' (expected running — 19D7 guard should protect a live session)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "no spurious ghost-reset heartbeat for fresh partial-progress row" || fail "spurious ghost-reset for fresh partial-progress row"

echo ""
echo "3. ALL phases complete + STALE mtime → left alone (finalize-completed-tasks.sh's job)"
r="$(run_reset "| ${TASK_ID} | fully done but still marked running | auto | 3 | running | $OLD_TS |" "$FULL_BODY" 20)"
[[ "${r%%|*}" == "running" ]] && ok "fully-complete row left alone (not ghost-reset)" || fail "status='${r%%|*}' (expected running — should be finalize's job, not this reaper's)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "no ghost-reset heartbeat for fully-complete row" || fail "spurious ghost-reset for fully-complete row"

# ── rescue.sh: same 3 scenarios against the inline mirror ──────────────────

echo ""
echo "── stale partial-progress ghost-reset (527A) — rescue.sh ───"

[[ -f "$RESCUE" ]] && ok "rescue.sh present" || fail "rescue.sh missing at $RESCUE"

# run_rescue <registry-row> <task-file-body> [task-file-mtime-min-ago]
run_rescue() {
  local row="$1"; local task_file_body="$2"; local mtime_min="${3:-}"
  local TMP; TMP="$(mktemp -d)"
  mkdir -p "$TMP/.orchestrate/tasks" "$TMP/.orchestrate/logs" "$TMP/.orchestrate/bin" \
    "$TMP/.orchestrate/inbox/gated" "$TMP/.orchestrate/inbox/processed"
  {
    echo "# Orchestrate — rescue-527A-test"
    echo "last_updated: 2026-01-01T00:00:00Z"
    echo ""
    echo "## Shared Context"
    echo ""
    echo "## Task Registry"
    echo "| ID | summary | mode | current_phase | status | last_activity |"
    echo "|----|---------|------|---------------|--------|---------------|"
    echo "$row"
  } > "$TMP/.orchestrate/project.md"
  printf '%s\n' "$task_file_body" > "$TMP/.orchestrate/tasks/${TASK_ID}.md"
  if [[ -n "$mtime_min" ]]; then
    local bt
    bt="$(date -v-"${mtime_min}"M +%Y%m%d%H%M 2>/dev/null || date -d "${mtime_min} minutes ago" +%Y%m%d%H%M)"
    touch -t "$bt" "$TMP/.orchestrate/tasks/${TASK_ID}.md"
  fi
  # NOTE: deliberately do NOT copy run-job.sh into the temp bin — rescue only
  # kicks it when present, so omitting it keeps this test side-effect-free.
  bash "$RESCUE" "$TMP" >/dev/null 2>&1 || true
  local status hb
  status="$(grep "$TASK_ID" "$TMP/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
  hb="$(grep -c "ghost-reset ${TASK_ID}: running→needs_human" "$TMP/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
  hb="${hb:-0}"
  echo "${status}|${hb}"
  rm -rf "$TMP"
}

echo ""
echo "4. rescue.sh: N-1 of N phases complete + STALE mtime → reset to needs_human"
r="$(run_rescue "| ${TASK_ID} | dispatching session died mid-run | auto | 3 | running | $OLD_TS |" "$PARTIAL_BODY" 20)"
[[ "${r%%|*}" == "needs_human" ]] && ok "rescue: partial-progress + stale mtime reset to needs_human" || fail "rescue status='${r%%|*}' (expected needs_human)"
[[ "$(echo "$r" | cut -d'|' -f2)" -ge 1 ]] && ok "rescue: ghost-reset heartbeat written" || fail "rescue: no ghost-reset heartbeat for stale partial-progress row"

echo ""
echo "5. rescue.sh: N-1 of N phases complete + FRESH mtime → left running"
r="$(run_rescue "| ${TASK_ID} | still actively writing phase 3 | auto | 3 | running | $OLD_TS |" "$PARTIAL_BODY" 0)"
[[ "${r%%|*}" == "running" ]] && ok "rescue: partial-progress + fresh mtime left running" || fail "rescue status='${r%%|*}' (expected running)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "rescue: no spurious ghost-reset heartbeat for fresh partial-progress row" || fail "rescue: spurious ghost-reset for fresh partial-progress row"

echo ""
echo "6. rescue.sh: ALL phases complete + STALE mtime → left alone"
r="$(run_rescue "| ${TASK_ID} | fully done but still marked running | auto | 3 | running | $OLD_TS |" "$FULL_BODY" 20)"
[[ "${r%%|*}" == "running" ]] && ok "rescue: fully-complete row left alone" || fail "rescue status='${r%%|*}' (expected running)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "rescue: no ghost-reset heartbeat for fully-complete row" || fail "rescue: spurious ghost-reset for fully-complete row"

echo ""
echo "── stale partial-progress ghost-reset (527A): $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
