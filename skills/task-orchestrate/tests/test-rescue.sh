#!/usr/bin/env bash
# test-rescue.sh — unit tests for .orchestrate/bin/rescue.sh stale-running reset.
#
# Regression (2026-06-27): rescue.sh reset stale `running` rows to `needs_human`
# but logged "reset stale running task <ID> → needs_human" — a string that
# tend-need-action.sh:42 does NOT recognize (it greps for the run-job.sh form
# "ghost-reset <ID>: running→needs_human"). Result: auto jobs rescue reset were
# never re-queued — they sat parked in needs_human as a dead-end, invisible to the
# requeue path. Fix: rescue emits the recognized ghost-reset token for AUTO rows
# (gated rows stay descriptive / non-requeue-eligible).
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
RESCUE="${RESCUE:-$PROJECT_ROOT/bin/rescue.sh}"
RESCUE_SRC="${RESCUE_SRC:-/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/bin/rescue.sh}"
NEED_ACTION="$PROJECT_ROOT/bin/tend-need-action.sh"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

echo ""
echo "── rescue.sh stale-running reset — test suite ───"

echo ""
echo "0. Prerequisites"
[[ -f "$RESCUE" ]] && ok "rescue.sh found" || { fail "rescue.sh missing at $RESCUE"; exit 1; }
if [[ -f "$RESCUE_SRC" ]] && cmp -s "$RESCUE_SRC" "$RESCUE" 2>/dev/null; then
  ok "installed rescue.sh matches ai-toolbox source"
elif [[ -f "$RESCUE_SRC" ]]; then
  fail "installed rescue.sh stale vs ai-toolbox source — run sync"
fi
bash -n "$RESCUE" 2>/dev/null && ok "rescue.sh bash syntax valid" || fail "rescue.sh syntax error"

# ── Build a temp project: stale auto + stale gated + fresh auto running rows ──
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rescue-test.XXXXXX")"
WORK="$TMP/work"
mkdir -p "$WORK/.orchestrate/logs" "$WORK/.orchestrate/bin" "$WORK/.orchestrate/tasks" \
  "$WORK/.orchestrate/inbox/gated" "$WORK/.orchestrate/inbox/processed"
# Copy the gate so the integration assertion uses the real recognizer.
cp "$NEED_ACTION" "$WORK/.orchestrate/bin/" 2>/dev/null || true
# NOTE: deliberately do NOT copy run-job.sh into the temp bin — rescue only kicks
# it when present, so omitting it keeps this test side-effect-free (no dispatch).
FRESH_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# ~12 min ago: older than the unified 600s bar but younger than the OLD 3600s bar.
# This row is the 14C8 gap case — it must now be reset (it would NOT have been
# under rescue's previous 3600s threshold).
MID_TS="$(date -u -v-12M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '12 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
# C829: A510 no-file grace boundaries (mirrors run-job.sh's NO_FILE_GRACE_SECS=1800/30m).
# NOFILE_GRACE_TS: 20m ago → past STALE_RUNNING_SECS (10m) but within grace (30m).
# NOFILE_GHOST_TS: 40m ago → past grace — genuinely-dead no-file ghost.
NOFILE_GRACE_TS="$(date -u -v-20M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
NOFILE_GHOST_TS="$(date -u -v-40M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '40 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
# A stale auto row WITH real phase progress (✓ complete) — the ✓-phase guard must
# leave it running even though it is well past the threshold.
cat > "$WORK/.orchestrate/tasks/progressing.md" << 'TF'
### Phase 1
status: ✓ complete
TF
# 19D7 liveness guard: a stale-by-last_activity auto row whose task file was just
# written (fresh mtime, NO ✓ phase) is a LIVE agent mid-phase — must stay running.
cat > "$WORK/.orchestrate/tasks/live-file.md" << 'TF'
### Phase 1
status: pending
TF
# mid-auto: give it a task file with an OLD mtime (past STALE_RUNNING_SECS) so the
# 19D7 liveness guard does NOT protect it. This isolates the pre-existing 14C8
# threshold-unification assertion (test 6) from the new C829 no-file-grace guard,
# which would otherwise protect a genuinely no-file row at this same age (12m is
# within the 30m grace) — a task file this age realistically already exists by 12m.
cat > "$WORK/.orchestrate/tasks/mid-auto.md" << 'TF'
### Phase 1
status: pending
TF
MID_MTIME="$(date -v-12M +%Y%m%d%H%M 2>/dev/null || date -d '12 minutes ago' +%Y%m%d%H%M)"
touch -t "$MID_MTIME" "$WORK/.orchestrate/tasks/mid-auto.md"
cat > "$WORK/.orchestrate/project.md" << EOF
# Orchestrate — rescue-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| stale-auto | stalled auto job | auto | 1 | running | 2026-01-01T00:00:00Z |
| stale-gated | stalled gated job | gated | 1 | running | 2026-01-01T00:00:00Z |
| mid-auto | gap-aged auto job | auto | 1 | running | $MID_TS |
| progressing | progressing auto job | auto | 2 | running | 2026-01-01T00:00:00Z |
| live-file | live agent mid-phase | auto | 1 | running | 2026-01-01T00:00:00Z |
| fresh-auto | fresh auto job | auto | 1 | running | $FRESH_TS |
| no-file-grace | slow-to-start no-file job | auto | 1 | running | $NOFILE_GRACE_TS |
| no-file-ghost | dead no-file job | auto | 1 | running | $NOFILE_GHOST_TS |
EOF

HEARTBEAT="$WORK/.orchestrate/logs/heartbeat.log"
bash "$RESCUE" "$WORK" >/dev/null 2>&1 || true

echo ""
echo "1. Stale AUTO running row → recognized ghost-reset token"
if grep -q 'ghost-reset stale-auto: running→needs_human' "$HEARTBEAT" 2>/dev/null; then
  ok "auto row logged with ghost-reset token (re-queue recognizer matches)"
else
  fail "auto row missing ghost-reset token — got: $(grep stale-auto "$HEARTBEAT" 2>/dev/null || echo none)"
fi

echo ""
echo "2. Stale GATED running row → descriptive, NOT re-queue-eligible"
if grep -q 'reset stale running task stale-gated' "$HEARTBEAT" 2>/dev/null \
   && ! grep -q 'ghost-reset stale-gated' "$HEARTBEAT" 2>/dev/null; then
  ok "gated row reset without ghost-reset token (stays human-blocked)"
else
  fail "gated row should NOT carry ghost-reset token — got: $(grep stale-gated "$HEARTBEAT" 2>/dev/null || echo none)"
fi

echo ""
echo "3. Fresh running row (< 600s) NOT reset"
if ! grep -q 'fresh-auto' "$HEARTBEAT" 2>/dev/null \
   && grep -qE '\| fresh-auto .*\| running \|' "$WORK/.orchestrate/project.md" 2>/dev/null; then
  ok "fresh running row left untouched"
else
  fail "fresh running row should not be reset (age < 3600s)"
fi

echo ""
echo "4. Registry updated: stale rows now needs_human"
if grep -qE '\| stale-auto .*\| needs_human \|' "$WORK/.orchestrate/project.md" 2>/dev/null \
   && grep -qE '\| stale-gated .*\| needs_human \|' "$WORK/.orchestrate/project.md" 2>/dev/null; then
  ok "both stale rows moved running → needs_human"
else
  fail "stale rows not transitioned to needs_human"
fi

echo ""
echo "5. Integration: tend-need-action now sees the rescue-reset AUTO job as actionable"
# This is the core regression: before the fix, NEEDS_HUMAN_ACTIONABLE stayed 0 for
# rescue-reset rows (string mismatch) and the queue dead-ended. The gated row must
# NOT inflate the count (no token + genuine human blocker).
GATE_OUT="$(bash "$WORK/.orchestrate/bin/tend-need-action.sh" "$WORK" 2>/dev/null || true)"
NHA="$(printf '%s\n' "$GATE_OUT" | grep '^NEEDS_HUMAN_ACTIONABLE=' | cut -d= -f2)"
if [[ "${NHA:-0}" -ge 1 ]]; then
  ok "NEEDS_HUMAN_ACTIONABLE=$NHA — rescue-reset auto job is now re-queue-eligible"
else
  fail "NEEDS_HUMAN_ACTIONABLE=$NHA — mismatch regressed: rescue-reset row not recognized"
fi

echo ""
echo "6. Unified 600s threshold (14C8 gap): mid-aged auto row (~12m) now reset"
# Before the fix rescue used 3600s, so a ghost older than run-job's 600s bar but
# younger than 3600s fell into a gap and was reset by neither reaper. It must now
# be reset by rescue too (same STALE_RUNNING_SECS as run-job).
if grep -q 'ghost-reset mid-auto: running→needs_human' "$HEARTBEAT" 2>/dev/null \
   && grep -qE '\| mid-auto .*\| needs_human \|' "$WORK/.orchestrate/project.md" 2>/dev/null; then
  ok "gap-aged row reset (threshold unified to 600s — no more 600/3600 gap)"
else
  fail "mid-aged row not reset — 14C8 threshold gap regressed: $(grep mid-auto "$HEARTBEAT" 2>/dev/null || echo none)"
fi

echo ""
echo "7. ✓-phase guard: stale row WITH completed phase is NOT reset"
# Lowering the threshold must not kill genuinely-progressing tasks. A row whose
# task file shows a ✓ complete phase is real progress, not a ghost.
if ! grep -q 'progressing' "$HEARTBEAT" 2>/dev/null \
   && grep -qE '\| progressing .*\| running \|' "$WORK/.orchestrate/project.md" 2>/dev/null; then
  ok "row with ✓ complete phase left running (guard mirrors run-job)"
else
  fail "progressing row should not be reset (has ✓ phase): $(grep progressing "$HEARTBEAT" 2>/dev/null || echo none)"
fi

echo ""
echo "8. 19D7 liveness guard: stale last_activity but FRESH task file → NOT reset"
# The row's last_activity is old, but its task file was written just now (fresh
# mtime, no ✓ phase) — an agent actively writing phase blocks, not a ghost.
if ! grep -q 'live-file' "$HEARTBEAT" 2>/dev/null \
   && grep -qE '\| live-file .*\| running \|' "$WORK/.orchestrate/project.md" 2>/dev/null; then
  ok "fresh-task-file row left running (liveness guard mirrors run-job)"
else
  fail "live-file row should not be reset (fresh mtime): $(grep live-file "$HEARTBEAT" 2>/dev/null || echo none)"
fi

echo ""
echo "9. C829 A510 no-file grace: no task file, past STALE but within grace (20m) → NOT reset"
# No task file exists for no-file-grace, so the 19D7 mtime guard cannot see it — only
# the NO_FILE_GRACE_SECS window protects this slow-but-alive session. Must stay
# running with no ghost-reset heartbeat (not churn-counted).
if ! grep -q 'no-file-grace' "$HEARTBEAT" 2>/dev/null \
   && grep -qE '\| no-file-grace .*\| running \|' "$WORK/.orchestrate/project.md" 2>/dev/null; then
  ok "no-file row within grace left running (slow-but-alive, not a ghost)"
else
  fail "no-file row within grace should not be reset (A510 grace missing in rescue.sh): $(grep no-file-grace "$HEARTBEAT" 2>/dev/null || echo none)"
fi

echo ""
echo "10. C829 A510 no-file grace: no task file, past grace (40m) → still reset (genuine ghost)"
# Same shape but last_activity is past NO_FILE_GRACE_SECS (30m) — a job that never
# came alive. The grace must not protect it: reset to needs_human with the
# recognized ghost-reset heartbeat token.
if grep -q 'ghost-reset no-file-ghost: running→needs_human' "$HEARTBEAT" 2>/dev/null \
   && grep -qE '\| no-file-ghost .*\| needs_human \|' "$WORK/.orchestrate/project.md" 2>/dev/null; then
  ok "no-file row past grace reset to needs_human (genuine ghost)"
else
  fail "no-file row past grace not reset — grace too broad: $(grep no-file-ghost "$HEARTBEAT" 2>/dev/null || echo none)"
fi

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED — see above" && exit 1
