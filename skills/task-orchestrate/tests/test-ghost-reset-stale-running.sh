#!/usr/bin/env bash
# test-ghost-reset-stale-running.sh — regression for task 20260627-inbox-14C8.
#
# Background (AC12 / 14C8): reset_stale_running_tasks (run-job.sh) had a
# detection/mutation SPLIT-BRAIN. The detection loop (`while IFS='|' read` over
# grep-matched rows) is NF-tolerant and would DETECT a phantom-extra-column stale
# `running` row, then the function logged a `ghost-reset` heartbeat line — but the
# mutation `awk` guarded on NF==8 and never flipped the row. Result: the heartbeat
# claimed a ghost-reset that never happened, the row stayed `running`, and T-4
# (which re-queues only `needs_human` rows) never recovered it. The stale auto job
# was "silently missed".
#
# Fix asserted here: a stale `running` row — well-formed OR phantom-column corrupt —
# is flipped to `needs_human` AND a `ghost-reset … running→needs_human` heartbeat
# line is written, in lockstep (the heartbeat never lies).
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNJOB="${RUNJOB:-$PROJECT_ROOT/.orchestrate/bin/run-job.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

OLD_TS="$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
FRESH_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# run_reset <registry-row> [task-file-contents]
# Builds a mock control plane, runs reset_stale_running_tasks against it, and echoes:
#   <final-status-of-row>|<count-of-ghost-reset-heartbeat-lines>|<NF-of-row>
run_reset() {
  local row="$1"; local task_file_body="${2:-}"
  local TMP; TMP="$(mktemp -d)"
  mkdir -p "$TMP/.orchestrate/tasks" "$TMP/.orchestrate/logs"
  {
    echo "# Orchestrate"
    echo "## Task Registry"
    echo "| ID | summary | mode | current_phase | status | last_activity |"
    echo "|----|---------|------|---------------|--------|---------------|"
    echo "$row"
  } > "$TMP/.orchestrate/project.md"
  [[ -n "$task_file_body" ]] && printf '%s\n' "$task_file_body" > "$TMP/.orchestrate/tasks/20260628-tst.md"
  (
    ROOT="$TMP"
    log_heartbeat() { echo "$*" >> "$ROOT/.orchestrate/logs/heartbeat.log"; }
    eval "$(awk '/^STALE_RUNNING_SECS=/{p=1} p{print} p&&/^reset_stale_running_tasks\(\) \{/{f=1} f&&/^\}/{exit}' "$RUNJOB")"
    reset_stale_running_tasks
  )
  local status nf hb
  status="$(grep '20260628-tst' "$TMP/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
  nf="$(grep '20260628-tst' "$TMP/.orchestrate/project.md" | awk -F'|' '{print NF}')"
  hb="$(grep -c 'ghost-reset 20260628-tst: running→needs_human' "$TMP/.orchestrate/logs/heartbeat.log" 2>/dev/null || echo 0)"
  echo "${status}|${hb}|${nf}"
  rm -rf "$TMP"
}

echo ""
echo "── ghost-reset stale-running (14C8) — test suite ───"

[[ -f "$RUNJOB" ]] && ok "run-job.sh present" || fail "run-job.sh missing at $RUNJOB"

echo ""
echo "1. Well-formed stale running row → flip + heartbeat (baseline)"
r="$(run_reset "| 20260628-tst | a stale wiki ingest job | auto | 1 | running | $OLD_TS |")"
[[ "${r%%|*}" == "needs_human" ]] && ok "flipped to needs_human" || fail "status='${r%%|*}' (expected needs_human)"
[[ "$(echo "$r" | cut -d'|' -f2)" -ge 1 ]] && ok "ghost-reset heartbeat written" || fail "no ghost-reset heartbeat"

echo ""
echo "2. Phantom-column corrupt row (NF==9) → flip + heartbeat + normalized (AC12 regression)"
# This is the exact corruption that defeated the pre-fix function: an extra timestamp
# column past last_activity. Pre-fix: row stayed 'running' though a heartbeat fired.
r="$(run_reset "| 20260628-tst | a stale wiki ingest job | auto | 1 | running | $OLD_TS | $FRESH_TS |")"
status="${r%%|*}"; hb="$(echo "$r" | cut -d'|' -f2)"; nf="$(echo "$r" | cut -d'|' -f3)"
[[ "$status" == "needs_human" ]] && ok "phantom row flipped to needs_human (no longer silently missed)" \
  || fail "phantom row status='$status' (expected needs_human — split-brain regression!)"
[[ "$hb" -ge 1 ]] && ok "phantom row ghost-reset heartbeat written" || fail "phantom row no heartbeat"
[[ "$nf" -eq 8 ]] && ok "phantom column self-healed to canonical NF==8" || fail "row NF=$nf (expected 8 — phantom column not collapsed)"

echo ""
echo "3. Heartbeat never lies: a ghost-reset line implies the row is needs_human"
# Combined invariant over cases 1+2: every ghost-reset line corresponds to a real flip.
if [[ "$status" == "needs_human" && "$hb" -ge 1 ]]; then
  ok "ghost-reset heartbeat ↔ status flip are in lockstep"
else
  fail "split-brain: heartbeat=$hb but status='$status'"
fi

echo ""
echo "4. Row with progress (✓ complete phase) → NOT reset"
r="$(run_reset "| 20260628-tst | partly done job | auto | 2 | running | $OLD_TS |" "### Phase 1
status: ✓ complete")"
[[ "${r%%|*}" == "running" ]] && ok "row with ✓ phase left running (not a ghost)" || fail "status='${r%%|*}' (expected running)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "no ghost-reset heartbeat for in-progress row" || fail "spurious ghost-reset for in-progress row"

echo ""
echo "5. Fresh running row (recent last_activity) → NOT reset"
r="$(run_reset "| 20260628-tst | just-dispatched job | auto | 1 | running | $FRESH_TS |")"
[[ "${r%%|*}" == "running" ]] && ok "fresh running row left running" || fail "status='${r%%|*}' (expected running — reset too eager)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "no ghost-reset heartbeat for fresh row" || fail "spurious ghost-reset for fresh row"

echo ""
echo "6. Lock-gated reap (AC12 root cause): ghost reset even when lock held by a LIVE pid"
# AC12 was the task a tend session was running when it wedged WHILE still holding
# .tend.lock. Every later cycle hit run-job's 'lock held by live pid → skipping
# cycle' branch and exited BEFORE the preflight reaper ran, so the stale `running`
# row it left behind was never reset (no ghost-reset line was ever written — the
# smoking gun). Fix: run-job reaps stale ghosts in that skip branch too.
LTMP="$(mktemp -d)"
mkdir -p "$LTMP/.orchestrate/logs" "$LTMP/.orchestrate/tasks"
{
  echo "# Orchestrate"
  echo "## Task Registry"
  echo "| ID | summary | mode | current_phase | status | last_activity |"
  echo "|----|---------|------|---------------|--------|---------------|"
  echo "| 20260628-lck | wedged-owner ghost | auto | 1 | running | $OLD_TS |"
} > "$LTMP/.orchestrate/project.md"
# Hold the lock with a real LIVE pid (background sleep) + a fresh acquire time.
sleep 30 & LIVE_PID=$!
printf '%s %s\n' "$LIVE_PID" "$FRESH_TS" > "$LTMP/.orchestrate/.tend.lock"
( cd "$LTMP" && bash "$RUNJOB" tend ) >/dev/null 2>&1 || true
kill "$LIVE_PID" 2>/dev/null || true
lstatus="$(grep '20260628-lck' "$LTMP/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
lhb="$(grep -c 'ghost-reset 20260628-lck: running→needs_human' "$LTMP/.orchestrate/logs/heartbeat.log" 2>/dev/null || echo 0)"
lskip="$(grep -c 'skipping cycle' "$LTMP/.orchestrate/logs/heartbeat.log" 2>/dev/null || echo 0)"
[[ "$lstatus" == "needs_human" ]] && ok "ghost reaped despite live lock holder (AC12 fixed)" || fail "status='$lstatus' (expected needs_human — lock-gating regression)"
[[ "$lhb" -ge 1 ]] && ok "ghost-reset heartbeat written under held lock" || fail "no ghost-reset heartbeat under held lock"
[[ "$lskip" -ge 1 ]] && ok "cycle still skipped (live lock respected, not reclaimed)" || fail "expected a skipping-cycle log line"
rm -rf "$LTMP"

echo ""
echo "── ghost-reset stale-running: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
