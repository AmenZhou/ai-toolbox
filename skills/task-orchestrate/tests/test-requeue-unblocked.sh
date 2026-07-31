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
# This copy lives at skills/task-orchestrate/tests/ in the ai-toolbox tree,
# where bin/ is a direct sibling of tests/ (skills/task-orchestrate/{bin,tests}),
# unlike the ai-console tree where bin/ and tests/ are siblings under
# .orchestrate/ (.orchestrate/{bin,tests}). Climb one level (tests/../ ==
# skills/task-orchestrate) and look for bin/ directly underneath — do not
# reuse ai-console's "climb two levels then re-add /.orchestrate/bin" logic,
# which only happens to work for that tree's nesting.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CG="${CG:-$PROJECT_ROOT/bin/churn-guard.sh}"
CG_SRC="${CG_SRC:-/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/bin/churn-guard.sh}"
REQUEUE="${REQUEUE:-$PROJECT_ROOT/bin/requeue-unblocked.sh}"
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
