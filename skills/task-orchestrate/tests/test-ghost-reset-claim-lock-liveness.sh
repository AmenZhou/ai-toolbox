#!/usr/bin/env bash
# test-ghost-reset-claim-lock-liveness.sh — regression for task 20260802-inbox-B358.
#
# Background: STALE_RUNNING_SECS=600 (10 min) is shorter than some legitimate
# single-phase task durations (a full test suite run, a multi-mirror sync).
# The pre-existing 19D7 mtime guard only protects a row while its task file is
# actively being WRITTEN — but a long single-phase agent can go quiet on both
# last_activity (updated only at phase checkpoints) and its task file's mtime
# for a stretch well past 600s while still genuinely working. Ghost-resetting
# such a row purely on wall-clock age accumulates a false churn-guard strike
# against a job that is simply slow, not dead.
#
# Fix (mirrors both rescue.sh and run-job.sh's reset_stale_running_tasks()):
# before ghost-resetting a stale `running` row, check claim_lock_is_live() for
# its ID. A live per-ID claim lock (claim-lock.sh) means the dispatching
# wrapper's recorded owner pid still answers `kill -0` — direct, independent
# evidence the session is alive, not a last_activity/mtime heuristic. This
# suite asserts: (1) a stale row WITH a live claim lock is NOT ghost-reset in
# either script, (2) the SAME row IS ghost-reset once the lock is released
# (no permanent over-protection), and (3) a stale row whose lock is present
# but DEAD (stale owner pid) is still ghost-reset normally (the guard does not
# blanket-protect on lock presence alone — only genuine liveness).
#
# Harness note (mirrors test-claim-lock-and-mark-cancelled.sh): claim-lock.sh
# is SOURCED in-process so an "acquired" lock is owned by this test script's
# own long-lived $$ — a subprocess's pid dies the instant that subprocess
# exits, which would make every "live owner" scenario indistinguishable from
# a dead one.
set -uo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
BIN="$PROJECT_ROOT/bin"
RUNJOB="${RUNJOB:-$BIN/run-job.sh}"
RESCUE="${RESCUE:-$BIN/rescue.sh}"
CLAIM_LOCK="$BIN/claim-lock.sh"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo ""
echo "── ghost-reset claim-lock liveness (ORCH-B358) — test suite ───"

echo ""
echo "0. Prerequisites"
[[ -f "$RUNJOB" ]] && ok "run-job.sh present" || fail "run-job.sh missing at $RUNJOB"
[[ -f "$RESCUE" ]] && ok "rescue.sh present" || fail "rescue.sh missing at $RESCUE"
[[ -f "$CLAIM_LOCK" ]] && ok "claim-lock.sh present" || { fail "claim-lock.sh missing at $CLAIM_LOCK"; exit 1; }
bash -n "$RUNJOB" 2>/dev/null && ok "run-job.sh bash syntax valid" || fail "run-job.sh syntax error"
bash -n "$RESCUE" 2>/dev/null && ok "rescue.sh bash syntax valid" || fail "rescue.sh syntax error"

# shellcheck disable=SC1090
source "$CLAIM_LOCK"

OLD_TS="$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"

# ── Section 1: run-job.sh reset_stale_running_tasks() (function-extraction, mirrors
#    test-ghost-reset-stale-running.sh's harness) ────────────────────────────────
echo ""
echo "1. run-job.sh: stale running row WITH a LIVE claim lock → NOT reset"
TMP1="$(mktemp -d)"
mkdir -p "$TMP1/.orchestrate/tasks" "$TMP1/.orchestrate/logs"
CLAIM_LOCK_ROOT="$TMP1"
claim_lock_acquire "20260628-lock"
(
  ROOT="$TMP1"
  CLAIM_LOCK_ROOT="$TMP1"
  log_heartbeat() { echo "$*" >> "$ROOT/.orchestrate/logs/heartbeat.log"; }
  {
    echo "# Orchestrate"
    echo "## Task Registry"
    echo "| ID | summary | mode | current_phase | status | last_activity |"
    echo "|----|---------|------|---------------|--------|---------------|"
    echo "| 20260628-lock | long single-phase job | auto | 1 | running | $OLD_TS |"
  } > "$ROOT/.orchestrate/project.md"
  eval "$(awk '/^STALE_RUNNING_SECS=/{p=1} p{print} p&&/^reset_stale_running_tasks\(\) \{/{f=1} f&&/^\}/{exit}' "$RUNJOB")"
  reset_stale_running_tasks
)
S1="$(grep '20260628-lock' "$TMP1/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
HB1="$(grep -c 'ghost-reset 20260628-lock: running→needs_human' "$TMP1/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
HB1="${HB1:-0}"
[[ "$S1" == "running" ]] && ok "row with live claim lock left running (slow, not dead)" || fail "status='$S1' (expected running — claim-lock guard missing)"
[[ "$HB1" -eq 0 ]] && ok "no ghost-reset heartbeat while claim lock is live" || fail "spurious ghost-reset heartbeat despite live claim lock"

echo ""
echo "2. run-job.sh: SAME row, claim lock released → normal ghost-reset resumes"
claim_lock_release "20260628-lock"
(
  ROOT="$TMP1"
  CLAIM_LOCK_ROOT="$TMP1"
  log_heartbeat() { echo "$*" >> "$ROOT/.orchestrate/logs/heartbeat.log"; }
  eval "$(awk '/^STALE_RUNNING_SECS=/{p=1} p{print} p&&/^reset_stale_running_tasks\(\) \{/{f=1} f&&/^\}/{exit}' "$RUNJOB")"
  reset_stale_running_tasks
)
S2="$(grep '20260628-lock' "$TMP1/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
HB2="$(grep -c 'ghost-reset 20260628-lock: running→needs_human' "$TMP1/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
HB2="${HB2:-0}"
[[ "$S2" == "needs_human" ]] && ok "row reset to needs_human once claim lock released (no permanent over-protection)" || fail "status='$S2' (expected needs_human after lock release)"
[[ "$HB2" -ge 1 ]] && ok "ghost-reset heartbeat written after lock release" || fail "no ghost-reset heartbeat after lock release"
rm -rf "$TMP1"

echo ""
echo "3. run-job.sh: stale running row with a DEAD-owner claim lock → still reset (no blanket protection)"
TMP3="$(mktemp -d)"
mkdir -p "$TMP3/.orchestrate/tasks" "$TMP3/.orchestrate/logs" "$TMP3/.orchestrate/locks/20260628-lock.claim"
printf '999999 2026-01-01T00:00:00Z\n' > "$TMP3/.orchestrate/locks/20260628-lock.claim/owner"
{
  echo "# Orchestrate"
  echo "## Task Registry"
  echo "| ID | summary | mode | current_phase | status | last_activity |"
  echo "|----|---------|------|---------------|--------|---------------|"
  echo "| 20260628-lock | job with a stale dead-owner lock | auto | 1 | running | $OLD_TS |"
} > "$TMP3/.orchestrate/project.md"
(
  ROOT="$TMP3"
  CLAIM_LOCK_ROOT="$TMP3"
  log_heartbeat() { echo "$*" >> "$ROOT/.orchestrate/logs/heartbeat.log"; }
  eval "$(awk '/^STALE_RUNNING_SECS=/{p=1} p{print} p&&/^reset_stale_running_tasks\(\) \{/{f=1} f&&/^\}/{exit}' "$RUNJOB")"
  reset_stale_running_tasks
)
S3="$(grep '20260628-lock' "$TMP3/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
HB3="$(grep -c 'ghost-reset 20260628-lock: running→needs_human' "$TMP3/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
HB3="${HB3:-0}"
[[ "$S3" == "needs_human" ]] && ok "row with a dead-owner lock still ghost-reset (guard checks liveness, not mere presence)" || fail "status='$S3' (expected needs_human — guard over-protecting on lock presence alone)"
[[ "$HB3" -ge 1 ]] && ok "ghost-reset heartbeat written for dead-owner-lock row" || fail "no ghost-reset heartbeat for dead-owner-lock row"
rm -rf "$TMP3"

# ── Section 2: rescue.sh (full-script invocation, mirrors test-rescue.sh's harness) ──
echo ""
echo "4. rescue.sh: stale running row WITH a LIVE claim lock → NOT reset"
RTMP="$(mktemp -d)"
W="$RTMP/work"
mkdir -p "$W/.orchestrate/tasks" "$W/.orchestrate/logs" "$W/.orchestrate/bin" \
  "$W/.orchestrate/inbox/gated" "$W/.orchestrate/inbox/processed"
cp "$CLAIM_LOCK" "$W/.orchestrate/bin/claim-lock.sh"
cat > "$W/.orchestrate/project.md" << EOF
# Orchestrate — rescue claim-lock test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| lock-live | long single-phase job | auto | 1 | running | $OLD_TS |
EOF
CLAIM_LOCK_ROOT="$W"
claim_lock_acquire "lock-live"
bash "$RESCUE" "$W" >/dev/null 2>&1 || true
RS1="$(grep 'lock-live' "$W/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
RHB1="$(grep -c 'ghost-reset lock-live: running→needs_human' "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
RHB1="${RHB1:-0}"
[[ "$RS1" == "running" ]] && ok "rescue.sh: row with live claim lock left running" || fail "rescue.sh: status='$RS1' (expected running — claim-lock guard missing)"
[[ "$RHB1" -eq 0 ]] && ok "rescue.sh: no ghost-reset heartbeat while claim lock is live" || fail "rescue.sh: spurious ghost-reset despite live claim lock"

echo ""
echo "5. rescue.sh: SAME row, claim lock released → normal ghost-reset resumes"
claim_lock_release "lock-live"
bash "$RESCUE" "$W" >/dev/null 2>&1 || true
RS2="$(grep 'lock-live' "$W/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
RHB2="$(grep -c 'ghost-reset lock-live: running→needs_human' "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
RHB2="${RHB2:-0}"
[[ "$RS2" == "needs_human" ]] && ok "rescue.sh: row reset to needs_human once claim lock released" || fail "rescue.sh: status='$RS2' (expected needs_human after lock release)"
[[ "$RHB2" -ge 1 ]] && ok "rescue.sh: ghost-reset heartbeat written after lock release" || fail "rescue.sh: no ghost-reset heartbeat after lock release"
rm -rf "$RTMP"

echo ""
echo "── ghost-reset claim-lock liveness: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
