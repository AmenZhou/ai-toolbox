#!/usr/bin/env bash
# test-max-running-duration-cap.sh — regression for task 20260731-inbox-7133
# (ORCH-2-IMPL), implementing the plan in reports/orchestrate/orch-2-inv_plan.md.
#
# Asserts enforce-max-running-duration.sh: a `running` row dispatched more than
# MAX_RUNNING_SECS (600s) ago — measured from the ISO prefix of its MOST RECENT
# `tend-auto — dispatching "<title>" (<ID>)` heartbeat line, NOT last_activity —
# is flipped to needs_human even with a fresh task file (activity is irrelevant);
# a row dispatched recently or with no resolvable dispatch line is left alone
# (fail-safe); mode: gated flips to needs_human (not awaiting_go); and the cap does
# not double-fire alongside reset_stale_running_tasks on the same row in one cycle.
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
SCRIPT="${SCRIPT:-$PROJECT_ROOT/bin/enforce-max-running-duration.sh}"
RUNJOB="${RUNJOB:-$PROJECT_ROOT/bin/run-job.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# Dispatch 15 min ago → past the 600s cap. Dispatch 5 min ago → within the cap.
DISP_OLD_TS="$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
DISP_FRESH_TS="$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
OLD_LA_TS="$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"

# Threshold-boundary timestamps: 610s ago (just OVER the 600s cap) and 590s ago
# (just UNDER it). A 10s margin on each side of the boundary avoids clock-jitter
# flakiness while still exercising the cutoff itself, unlike the 15min/5min
# fixtures above which only prove the cap works far from the boundary.
DISP_JUST_OVER_TS="$(date -u -v-610S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '610 seconds ago' +%Y-%m-%dT%H:%M:%SZ)"
DISP_JUST_UNDER_TS="$(date -u -v-590S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '590 seconds ago' +%Y-%m-%dT%H:%M:%SZ)"

TID="20260731-cap"

# build_plane <TMP> <row> [dispatch_ts] [task_file_body] [task_file_mtime_min_ago]
# Writes a mock control plane; optionally a dispatch heartbeat line and a task file.
build_plane() {
  local tmp="$1" row="$2" disp_ts="${3:-}" tf_body="${4:-}" tf_mtime_min="${5:-}"
  mkdir -p "$tmp/.orchestrate/tasks" "$tmp/.orchestrate/logs" "$tmp/.orchestrate/bin"
  {
    echo "# Orchestrate"
    echo "## Task Registry"
    echo "| ID | summary | mode | current_phase | status | last_activity |"
    echo "|----|---------|------|---------------|--------|---------------|"
    echo "$row"
  } > "$tmp/.orchestrate/project.md"
  if [[ -n "$disp_ts" ]]; then
    echo "[$disp_ts] tend-auto — dispatching \"a long-running job\" ($TID) [batch 1] [session=orchestrate_shell_probe_1700000000_12345_9]" \
      >> "$tmp/.orchestrate/logs/heartbeat.log"
  fi
  if [[ -n "$tf_body" ]]; then
    printf '%s\n' "$tf_body" > "$tmp/.orchestrate/tasks/${TID}.md"
    if [[ -n "$tf_mtime_min" ]]; then
      local bt
      bt="$(date -v-"${tf_mtime_min}"M +%Y%m%d%H%M 2>/dev/null || date -d "${tf_mtime_min} minutes ago" +%Y%m%d%H%M)"
      touch -t "$bt" "$tmp/.orchestrate/tasks/${TID}.md"
    fi
  fi
}

# run_cap <row> [dispatch_ts] [task_file_body] [task_file_mtime_min_ago]
# Runs the cap script and echoes: <final-status>|<max-runtime-cap-hb-count>|<row-NF>
run_cap() {
  local TMP; TMP="$(mktemp -d)"
  build_plane "$TMP" "$1" "${2:-}" "${3:-}" "${4:-}"
  bash "$SCRIPT" "$TMP" >/dev/null 2>&1 || true
  local status nf hb
  status="$(grep "$TID" "$TMP/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
  nf="$(grep "$TID" "$TMP/.orchestrate/project.md" | awk -F'|' '{print NF}')"
  hb="$(grep -c "max-runtime-cap ${TID}: running→needs_human" "$TMP/.orchestrate/logs/heartbeat.log" 2>/dev/null)"
  hb="${hb:-0}"
  echo "${status}|${hb}|${nf}"
  rm -rf "$TMP"
}

FRESH_TF="# Task
id: ${TID}
total_phases: 1

### Phase 1: do the thing
status: pending
"

echo ""
echo "── max-running-duration cap (ORCH-2) — test suite ───"

[[ -f "$SCRIPT" ]] && ok "enforce-max-running-duration.sh present" || fail "script missing at $SCRIPT"

echo ""
echo "(a) dispatched >10 min ago WITH a fresh task file → flipped to needs_human (activity ignored)"
r="$(run_cap "| $TID | a long-running job | auto | 1 | running | $OLD_LA_TS |" "$DISP_OLD_TS" "$FRESH_TF" 0)"
[[ "${r%%|*}" == "needs_human" ]] && ok "flipped to needs_human despite fresh task file" || fail "status='${r%%|*}' (expected needs_human)"
[[ "$(echo "$r" | cut -d'|' -f2)" -ge 1 ]] && ok "max-runtime-cap heartbeat written" || fail "no max-runtime-cap heartbeat"
[[ "$(echo "$r" | cut -d'|' -f3)" -eq 8 ]] && ok "row stays NF==8" || fail "row NF != 8"

echo ""
echo "(b) dispatched <10 min ago → left running (under the cap)"
r="$(run_cap "| $TID | a long-running job | auto | 1 | running | $OLD_LA_TS |" "$DISP_FRESH_TS" "$FRESH_TF" 0)"
[[ "${r%%|*}" == "running" ]] && ok "recent dispatch left running" || fail "status='${r%%|*}' (expected running)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "no heartbeat for under-cap row" || fail "spurious cap heartbeat"

echo ""
echo "(c) no resolvable dispatch line → left running (fail-safe, cannot determine dispatch time)"
r="$(run_cap "| $TID | a long-running job | auto | 1 | running | $OLD_LA_TS |")"
[[ "${r%%|*}" == "running" ]] && ok "no-dispatch-line row left running (fail-safe)" || fail "status='${r%%|*}' (expected running — must not flip without a clock)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "no heartbeat for no-dispatch-line row" || fail "spurious cap heartbeat with no dispatch line"

echo ""
echo "(d) mode: gated dispatched >10 min ago → flipped to needs_human (NOT awaiting_go)"
r="$(run_cap "| $TID | a long-running gated job | gated | 1 | running | $OLD_LA_TS |" "$DISP_OLD_TS" "$FRESH_TF" 0)"
[[ "${r%%|*}" == "needs_human" ]] && ok "gated row flipped to needs_human (matches reset_stale precedent)" || fail "status='${r%%|*}' (expected needs_human — cap must not send gated to awaiting_go)"
[[ "$(echo "$r" | cut -d'|' -f3)" -eq 8 ]] && ok "gated row stays NF==8" || fail "gated row NF != 8"

echo ""
echo "(e) no double-fire with reset_stale_running_tasks (ordering guarantee)"
# Load reset_stale_running_tasks from run-job.sh WITHOUT executing its top-level
# dispatch (same eval-extract trick as test-ghost-reset-stale-running.sh).
# Control (e1): on a stale, reset-eligible running row, reset_stale ALONE ghost-resets it.
CTL="$(mktemp -d)"
build_plane "$CTL" "| $TID | a long-running job | auto | 1 | running | $OLD_LA_TS |" "$DISP_OLD_TS" "$FRESH_TF" 15
(
  ROOT="$CTL"
  log_heartbeat() { echo "$*" >> "$ROOT/.orchestrate/logs/heartbeat.log"; }
  eval "$(awk '/^STALE_RUNNING_SECS=/{p=1} p{print} p&&/^reset_stale_running_tasks\(\) \{/{f=1} f&&/^\}/{exit}' "$RUNJOB")"
  reset_stale_running_tasks
)
ctl_status="$(grep "$TID" "$CTL/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
ctl_ghost="$(grep -c "ghost-reset ${TID}" "$CTL/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"; ctl_ghost="${ctl_ghost:-0}"
[[ "$ctl_status" == "needs_human" && "$ctl_ghost" -ge 1 ]] && ok "control: reset_stale alone DOES ghost-reset this fixture (so it is reset-eligible)" || fail "control fixture not reset-eligible (status='$ctl_status', ghost=$ctl_ghost) — (e) would be vacuous"
rm -rf "$CTL"

# Ordering (e2): cap runs first (flips to needs_human), THEN reset_stale is a no-op.
ORD="$(mktemp -d)"
build_plane "$ORD" "| $TID | a long-running job | auto | 1 | running | $OLD_LA_TS |" "$DISP_OLD_TS" "$FRESH_TF" 15
bash "$SCRIPT" "$ORD" >/dev/null 2>&1 || true
(
  ROOT="$ORD"
  log_heartbeat() { echo "$*" >> "$ROOT/.orchestrate/logs/heartbeat.log"; }
  eval "$(awk '/^STALE_RUNNING_SECS=/{p=1} p{print} p&&/^reset_stale_running_tasks\(\) \{/{f=1} f&&/^\}/{exit}' "$RUNJOB")"
  reset_stale_running_tasks
)
ord_status="$(grep "$TID" "$ORD/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
ord_cap="$(grep -c "max-runtime-cap ${TID}: running→needs_human" "$ORD/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"; ord_cap="${ord_cap:-0}"
ord_ghost="$(grep -c "ghost-reset ${TID}" "$ORD/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"; ord_ghost="${ord_ghost:-0}"
[[ "$ord_status" == "needs_human" ]] && ok "cap+reset_stale leaves row needs_human" || fail "status='$ord_status' (expected needs_human)"
[[ "$ord_cap" -eq 1 ]] && ok "exactly one max-runtime-cap heartbeat (cap fired once)" || fail "max-runtime-cap count=$ord_cap (expected 1)"
[[ "$ord_ghost" -eq 0 ]] && ok "reset_stale did NOT ghost-reset the capped row (no double-fire)" || fail "ghost-reset count=$ord_ghost (expected 0 — double-fire!)"
rm -rf "$ORD"

echo ""
echo "(f) phantom-column corrupt row (NF==9) past the cap → flip + self-heal to NF==8"
r="$(run_cap "| $TID | a long-running job | auto | 1 | running | $OLD_LA_TS | $DISP_FRESH_TS |" "$DISP_OLD_TS" "$FRESH_TF" 0)"
[[ "${r%%|*}" == "needs_human" ]] && ok "phantom row flipped to needs_human" || fail "phantom row status='${r%%|*}' (expected needs_human)"
[[ "$(echo "$r" | cut -d'|' -f3)" -eq 8 ]] && ok "phantom column self-healed to NF==8" || fail "row NF=$(echo "$r" | cut -d'|' -f3) (expected 8)"

echo ""
echo "(g) dispatched just OVER the 600s cap (610s ago) → flipped to needs_human (boundary check)"
r="$(run_cap "| $TID | a long-running job | auto | 1 | running | $OLD_LA_TS |" "$DISP_JUST_OVER_TS" "$FRESH_TF" 0)"
[[ "${r%%|*}" == "needs_human" ]] && ok "610s-ago dispatch flipped (age >= MAX_RUNNING_SECS)" || fail "status='${r%%|*}' (expected needs_human)"
[[ "$(echo "$r" | cut -d'|' -f2)" -ge 1 ]] && ok "max-runtime-cap heartbeat written at boundary" || fail "no max-runtime-cap heartbeat at boundary"

echo ""
echo "(h) dispatched just UNDER the 600s cap (590s ago) → left running (boundary check)"
r="$(run_cap "| $TID | a long-running job | auto | 1 | running | $OLD_LA_TS |" "$DISP_JUST_UNDER_TS" "$FRESH_TF" 0)"
[[ "${r%%|*}" == "running" ]] && ok "590s-ago dispatch left running (age < MAX_RUNNING_SECS)" || fail "status='${r%%|*}' (expected running)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "no heartbeat just under the boundary" || fail "spurious cap heartbeat just under the boundary"

echo ""
echo "(i) already-non-running row (completed) with a very old dispatch line → untouched"
r="$(run_cap "| $TID | a long-running job | auto | 1 | completed | $OLD_LA_TS |" "$DISP_OLD_TS" "$FRESH_TF" 0)"
[[ "${r%%|*}" == "completed" ]] && ok "completed row left completed (cap only scans status==running)" || fail "status='${r%%|*}' (expected completed — cap must never touch non-running rows)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "no heartbeat for a non-running row" || fail "spurious cap heartbeat on a completed row"

echo ""
echo "── max-running-duration cap: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
