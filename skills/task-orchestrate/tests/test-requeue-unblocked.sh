#!/usr/bin/env bash
# test-requeue-unblocked.sh — requeue-unblocked.sh's churn-counter integration
# (20260729-inbox-2408/C94E root cause).
#
# Bug: set_pending() called raw cg_increment() unconditionally, so a requeue
# driven by run-job.sh's own auto-injected "Auto-reset: task stuck in running
# ..." human_resolution line got counted toward churn EVEN WHEN the underlying
# ghost-reset was itself shell_incapable/transient and had already been
# correctly excluded (not counted) by run-job.sh's own
# cg_increment_unless_transient call at reset time. 3 consecutive
# dispatch-starvation cycles — each individually "not counted" at the
# ghost-reset step — still parked the task via this leg's blind increment.
#
# Fix: set_pending() now calls cg_increment_unless_transient(id, since_epoch),
# where since_epoch is derived from the row's own last_activity (the time it
# went needs_human), so the requeue leg applies the SAME shell_incapable/
# transient classification as the reset leg instead of re-counting blindly.
set -uo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CG="${CG:-$PROJECT_ROOT/.orchestrate/bin/churn-guard.sh}"
CG_SRC="${CG_SRC:-/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/bin/churn-guard.sh}"
REQUEUE="${REQUEUE:-$PROJECT_ROOT/.orchestrate/bin/requeue-unblocked.sh}"
REQUEUE_SRC="${REQUEUE_SRC:-/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/bin/requeue-unblocked.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

echo ""
echo "── requeue-unblocked.sh — churn-counter classification — test suite ───"

echo ""
echo "0. Prerequisites"
[[ -f "$REQUEUE" ]] && ok "requeue-unblocked.sh found" || { fail "requeue-unblocked.sh missing at $REQUEUE"; exit 1; }
if [[ -f "$REQUEUE_SRC" ]] && cmp -s "$REQUEUE_SRC" "$REQUEUE" 2>/dev/null; then
  ok "installed requeue-unblocked.sh matches ai-toolbox source"
elif [[ -f "$REQUEUE_SRC" ]]; then
  fail "installed requeue-unblocked.sh stale vs ai-toolbox source — run sync"
fi
bash -n "$REQUEUE" 2>/dev/null && ok "requeue-unblocked.sh bash syntax valid" || fail "requeue-unblocked.sh syntax error"

setup_work() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/requeue-unblocked-test.XXXXXX")"
  W="$TMP/work"
  mkdir -p "$W/.orchestrate/logs" "$W/.orchestrate/tasks" "$W/.orchestrate/bin"
  cp "$CG" "$REQUEUE" "$W/.orchestrate/bin/" 2>/dev/null || true
}

count_of() {
  bash "$W/.orchestrate/bin/churn-guard.sh" cg_count "$W" "$1"
}

set_row() {
  local id="$1" ts="$2" st="$3"
  cat > "$W/.orchestrate/project.md" <<EOF
# Test
last_updated: $ts

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $id | test task | auto | 1 | $st | $ts |
EOF
}

# ── Case A: 3 consecutive shell_incapable ghost-reset+requeue cycles ─────────
# must NOT park (regression test for the 2408/C94E false-positive bug).
echo ""
echo "── Case A: 3 consecutive shell_incapable cycles do not park ────────────"
setup_work
SID="20260729-shellcap"
cat > "$W/.orchestrate/tasks/${SID}.md" <<EOF
id: $SID
task: test shell_incapable requeue
mode: auto
total_phases: 1

## Phases
### Phase 1
status: pending
EOF

for i in 1 2 3; do
  TS="2026-07-29T0$((3+i)):00:00Z"
  set_row "$SID" "$TS" "needs_human"
  echo "[$TS] no shell capability; deferred" >> "$W/.orchestrate/logs/heartbeat.log"
  printf 'human_resolution: Auto-reset: task stuck in running for 70%sd with no phase progress (tend session likely died)\n' "$i" \
    >> "$W/.orchestrate/tasks/${SID}.md"
  bash "$W/.orchestrate/bin/requeue-unblocked.sh" "$W" >/dev/null
done

c="$(count_of "$SID")"
[[ "$c" == "0" ]] && ok "counter stays 0 after 3 shell_incapable requeue cycles (was: false park bug)" \
  || fail "expected counter 0 after 3 shell_incapable cycles — got $c"

if grep -qE '^bypassed_at:' "$W/.orchestrate/tasks/${SID}.md" 2>/dev/null; then
  fail "task wrongly parked (bypassed_at present) after 3 shell_incapable cycles"
else
  ok "task NOT parked after 3 shell_incapable cycles"
fi

st="$(awk -F'|' -v id="$SID" '$0 ~ "\\| "id" \\|" { gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6; exit }' "$W/.orchestrate/project.md")"
[[ "$st" == "pending" ]] && ok "row left requeued to pending (not needs_human)" \
  || fail "expected row status pending — got '$st'"

# ── Case B: 3 consecutive genuine (non-shell_incapable) requeue cycles ───────
# must still park at threshold — this fix must not weaken real churn detection.
echo ""
echo "── Case B: genuine repeated churn (no shell_incapable/transient signal) still parks ───"
setup_work
GID="20260729-genuine"
cat > "$W/.orchestrate/tasks/${GID}.md" <<EOF
id: $GID
task: test genuine churn
mode: auto
total_phases: 1

## Phases
### Phase 1
status: pending
EOF

for i in 1 2 3; do
  TS="2026-07-29T1$((3+i)):00:00Z"
  set_row "$GID" "$TS" "needs_human"
  printf 'human_resolution: human fixed it, attempt %s\n' "$i" >> "$W/.orchestrate/tasks/${GID}.md"
  bash "$W/.orchestrate/bin/requeue-unblocked.sh" "$W" >/dev/null
done

c2="$(count_of "$GID")"
[[ "$c2" == "3" ]] && ok "counter reaches 3 for genuine repeated churn (unweakened)" \
  || fail "expected counter 3 for genuine churn — got $c2"

if grep -qE '^bypassed_at:.*' "$W/.orchestrate/tasks/${GID}.md" 2>/dev/null && \
   grep -qE '^bypass_reason: churn' "$W/.orchestrate/tasks/${GID}.md" 2>/dev/null; then
  ok "genuinely churning task IS parked (bypassed_at + bypass_reason present)"
else
  fail "genuinely churning task was not parked — churn detection broken"
fi

st2="$(awk -F'|' -v id="$GID" '$0 ~ "\\| "id" \\|" { gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6; exit }' "$W/.orchestrate/project.md")"
[[ "$st2" == "needs_human" ]] && ok "row left parked at needs_human" \
  || fail "expected row status needs_human — got '$st2'"

# ── Case C: mode:gated row requeues to awaiting_go, never pending (§2b companion fix) ──
# 20260730-inbox-988B / 20260730-inbox-AB08 verification: once churn-guard.sh's
# mode-aware guard means cg_park_if_churned no longer intercepts a gated row's
# set_pending() call, the unconditional awk flip at the bottom of set_pending()
# would (pre-fix) sweep the row straight to `pending` — silently dropping the
# human-approval gate and letting it get swept into the next `tend go auto`
# batch (the exact 20260725-inbox-4C3D hazard). Fix: mode is threaded into
# set_pending() and a gated row's reset target is `awaiting_go`, not `pending`.
echo ""
echo "── Case C: mode:gated needs_human row requeues to awaiting_go, never pending ────────"
setup_work
GATEID="20260730-gatedreq"
cat > "$W/.orchestrate/tasks/${GATEID}.md" <<EOF
id: $GATEID
task: test gated requeue target
mode: gated
total_phases: 1

## Phases
### Phase 1
status: pending
human_resolution: Auto-reset: task stuck in running for 700s (tend session likely died)
EOF
cat > "$W/.orchestrate/project.md" <<EOF
# Test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $GATEID | test gated requeue target | gated | 1 | needs_human | 2026-07-30T09:00:00Z |
EOF
bash "$W/.orchestrate/bin/requeue-unblocked.sh" "$W" >/dev/null

gst3="$(awk -F'|' -v id="$GATEID" '$0 ~ "\\| "id" \\|" { gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6; exit }' "$W/.orchestrate/project.md")"
if [[ "$gst3" == "awaiting_go" ]]; then
  ok "gated row requeued to awaiting_go (human-approval gate preserved)"
elif [[ "$gst3" == "pending" ]]; then
  fail "gated row was swept to pending — human-approval gate silently dropped (regression!)"
else
  fail "gated row landed in unexpected status: '$gst3'"
fi
gc3="$(count_of "$GATEID")"
[[ "$gc3" == "0" ]] && ok "gated row's churn counter stayed 0 through the requeue" \
  || fail "gated row's churn counter moved: $gc3 (expected 0)"

# ── Case D: shell_incapable evidence PRECEDES last_activity (real-world gap) ──
# SHELLPROBE-CHURN-1 (20260731-inbox-273D root cause): Case A's "no shell
# capability; deferred" line shares the SAME timestamp as last_activity, which
# only accidentally passes the `ts >= since` scan. In production, run-job.sh's
# reset_stale_running_tasks stamps last_activity to the RESET time — strictly
# AFTER the deferred line that occurred during the dispatch cycle that went
# stale. A since_epoch anchored to last_activity (post-reset) therefore misses
# the deferred evidence and silently falls through to a real cg_increment,
# parking a task purely on dispatch-starvation. Reproduce that gap explicitly:
# dispatch line at T+0, deferred line at T+5, last_activity/reset at T+20.
echo ""
echo "── Case D: shell_incapable evidence precedes last_activity (real-world gap) ──"
setup_work
GAPID="20260731-gapcase"
cat > "$W/.orchestrate/tasks/${GAPID}.md" <<EOF
id: $GAPID
task: test shell_incapable gap requeue
mode: auto
total_phases: 1

## Phases
### Phase 1
status: pending
EOF

for i in 1 2 3; do
  base_h=$((3+i))
  DISPATCH_TS="2026-07-31T0${base_h}:00:00Z"
  DEFERRED_TS="2026-07-31T0${base_h}:05:00Z"
  RESET_TS="2026-07-31T0${base_h}:20:00Z"
  echo "[$DISPATCH_TS] tend-auto — dispatching \"gap case\" (${GAPID}) [batch 1]" >> "$W/.orchestrate/logs/heartbeat.log"
  echo "[$DEFERRED_TS] no shell capability; deferred" >> "$W/.orchestrate/logs/heartbeat.log"
  set_row "$GAPID" "$RESET_TS" "needs_human"
  printf 'human_resolution: Auto-reset: task stuck in running for 120%sd with no phase progress (tend session likely died)\n' "$i" \
    >> "$W/.orchestrate/tasks/${GAPID}.md"
  bash "$W/.orchestrate/bin/requeue-unblocked.sh" "$W" >/dev/null
done

cd_="$(count_of "$GAPID")"
[[ "$cd_" == "0" ]] && ok "counter stays 0 across 3 gap cycles (dispatch precedes deferred precedes reset)" \
  || fail "expected counter 0 across 3 gap cycles — got $cd_ (since_epoch anchored too late)"

if grep -qE '^bypassed_at:' "$W/.orchestrate/tasks/${GAPID}.md" 2>/dev/null; then
  fail "gap-case task wrongly parked (bypassed_at present)"
else
  ok "gap-case task NOT parked"
fi

# ── Case E: zero-progress ghost-reset episode is NOT double-counted ─────────
# SHELLPROBE-CHURN-2 (20260731-inbox-5632/B560 root cause): a GENUINE
# (non-transient) zero-progress ghost-reset — the row never completed a
# single phase because its own dispatching session died mid-batch — was
# still counted TWICE per episode: once by the ghost-reset leg itself
# (rescue.sh / run-job.sh's reset_stale_running_tasks calling
# cg_increment_unless_transient the moment it flips running→needs_human), and
# AGAIN by this script's set_pending() the moment it saw the auto-injected
# "Auto-reset: task stuck in running ... (tend session likely died)" /
# "never actually executed" human_resolution and cleared the row back to
# pending. Two real ghost-reset episodes (2 increments each = 4) blew past
# CG_THRESHOLD=3 and parked the task after only 1.5 real dispatch attempts —
# 20260731-inbox-5632 and its sibling 20260731-inbox-B560 both parked this
# way despite Phase 1 having NEVER actually run.
#
# Fix: is_zero_progress_session_death_requeue() detects "zero ✓ complete
# phases AND an auto-injected session-death human_resolution", and set_pending
# skips ITS OWN increment in that case (skip_count=1) — the ghost-reset leg's
# increment (simulated directly below via cg_increment_unless_transient, the
# same call rescue.sh/run-job.sh make) is left as the ONLY count for that
# episode. A genuinely churning task (Case B) is unaffected — unweakened.
echo ""
echo "── Case E: zero-progress ghost-reset episode is not double-counted ─────"
setup_work
EID="20260731-shellprobe-5632-like"
cat > "$W/.orchestrate/tasks/${EID}.md" <<EOF
id: $EID
task: Tests for SHELLPROBE-1-IMPL
mode: auto
total_phases: 1

## Phases
### Phase 1
status: pending
EOF

for i in 1 2; do
  TS="2026-07-31T1$((3+i)):00:00Z"
  since_epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$TS" '+%s' 2>/dev/null || echo 0)"
  set_row "$EID" "$TS" "needs_human"
  # Simulates the ghost-reset leg itself (rescue.sh / run-job.sh) bumping the
  # counter the moment it flips running→needs_human — no transient/
  # shell_incapable evidence exists in this fresh workdir, so this is a real,
  # counted, genuine ghost-reset (episode #$i).
  bash "$W/.orchestrate/bin/churn-guard.sh" cg_increment_unless_transient "$W" "$EID" "$since_epoch" >/dev/null
  printf 'human_resolution: Auto-reset: task stuck in running for 99%ss with no phase progress (tend session likely died)\n' "$i" \
    >> "$W/.orchestrate/tasks/${EID}.md"
  bash "$W/.orchestrate/bin/requeue-unblocked.sh" "$W" >/dev/null
done

ce="$(count_of "$EID")"
[[ "$ce" == "2" ]] && ok "counter is 2 (one per real episode) after 2 ghost-reset+requeue cycles — was: 4 (double-counted)" \
  || fail "expected counter 2 after 2 zero-progress ghost-reset cycles — got $ce (double-counting regression)"

if grep -qE '^bypassed_at:' "$W/.orchestrate/tasks/${EID}.md" 2>/dev/null; then
  fail "task wrongly parked after only 2 real ghost-reset episodes (false churn park)"
else
  ok "task NOT parked after 2 real zero-progress ghost-reset episodes"
fi

# A 3rd genuine ghost-reset episode SHOULD still park — the fix must not
# suppress real churn detection, only the double-count.
TS3="2026-07-31T20:00:00Z"
since_epoch3="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$TS3" '+%s' 2>/dev/null || echo 0)"
set_row "$EID" "$TS3" "needs_human"
bash "$W/.orchestrate/bin/churn-guard.sh" cg_increment_unless_transient "$W" "$EID" "$since_epoch3" >/dev/null
bash "$W/.orchestrate/bin/churn-guard.sh" cg_park_if_churned "$W" "$EID" >/dev/null 2>&1 || true

ce3="$(count_of "$EID")"
[[ "$ce3" == "3" ]] && ok "counter reaches 3 on the 3rd genuine ghost-reset episode" \
  || fail "expected counter 3 after 3rd genuine ghost-reset — got $ce3"

if grep -qE '^bypassed_at:' "$W/.orchestrate/tasks/${EID}.md" 2>/dev/null; then
  ok "task correctly parked after 3 genuine ghost-reset episodes (real churn detection unweakened)"
else
  fail "task was NOT parked after 3 genuine ghost-reset episodes — real churn detection broken"
fi

# ── Case F: partial-progress task with session-death wording still counts ───
# is_zero_progress_session_death_requeue's own gate requires BOTH zero
# ✓-complete phases AND session-death phrasing. Case E only ever exercised a
# task with zero complete phases; this case exercises the OTHER edge of that
# same gate — a task that has already completed Phase 1 (real progress
# happened) hits a session-death-worded reset on Phase 2. This must NOT be
# treated as a free (skip_count=1) ghost-reset episode — a real dispatch
# attempt occurred and produced progress, so the double-count concern
# (SHELLPROBE-CHURN-2) does not apply here; suppressing this leg's own
# increment would silently under-count a genuinely churning task merely
# because its human_resolution happens to reuse session-death-shaped wording.
# Verifies the "complete -eq 0" precondition in is_zero_progress_session_death_requeue
# is load-bearing, not vestigial.
echo ""
echo "── Case F: partial-progress (≥1 complete phase) + session-death wording still counts ───"
setup_work
FID="20260731-partialprogress"
cat > "$W/.orchestrate/tasks/${FID}.md" <<EOF
id: $FID
task: test partial-progress session-death wording
mode: auto
total_phases: 2

## Phases
### Phase 1
status: ✓ complete

### Phase 2
status: pending
EOF

for i in 1 2 3; do
  TS="2026-07-31T2$((3+i)):00:00Z"
  set_row "$FID" "$TS" "needs_human"
  printf 'human_resolution: Auto-reset: task stuck in running for 55%ss with no phase progress (tend session likely died)\n' "$i" \
    >> "$W/.orchestrate/tasks/${FID}.md"
  bash "$W/.orchestrate/bin/requeue-unblocked.sh" "$W" >/dev/null
done

cf="$(count_of "$FID")"
[[ "$cf" == "3" ]] && ok "counter reaches 3 for partial-progress task despite session-death wording (skip gate correctly did not fire)" \
  || fail "expected counter 3 for partial-progress + session-death wording — got $cf (skip gate over-firing on a completed-phase task)"

if grep -qE '^bypassed_at:.*' "$W/.orchestrate/tasks/${FID}.md" 2>/dev/null && \
   grep -qE '^bypass_reason: churn' "$W/.orchestrate/tasks/${FID}.md" 2>/dev/null; then
  ok "partial-progress task IS parked at threshold (real churn detection unweakened by the complete-phase gate)"
else
  fail "partial-progress task was not parked — churn detection wrongly suppressed by session-death wording despite prior real progress"
fi

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  echo "  ALL TESTS PASSED"
  exit 0
else
  echo "  SOME TESTS FAILED"
  exit 1
fi
