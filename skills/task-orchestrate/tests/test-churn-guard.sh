#!/usr/bin/env bash
# test-churn-guard.sh — churn guard: block tasks re-processed 3× (poison-task net).
#
# Drives a task through 3 requeue cycles and asserts:
#   - the shared counter increments on every requeue (task-file AND no-file ghost)
#   - the 3rd cycle parks it as blocked (needs_human + bypassed_at + bypass_reason)
#   - an async investigation job is auto-filed (source:self, mode:auto, triggered_by)
#   - a second run does NOT double-file (dedup on triggered_by)
#   - the counter resets to 0 on complete (cg_reset)
#   - registry NF==8 invariant is preserved across the park
set -uo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CG="${CG:-$PROJECT_ROOT/.orchestrate/bin/churn-guard.sh}"
CG_SRC="${CG_SRC:-/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/bin/churn-guard.sh}"
REQUEUE="${REQUEUE:-$PROJECT_ROOT/.orchestrate/bin/requeue-unblocked.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

echo ""
echo "── churn guard — block tasks re-processed 3× — test suite ───"

echo ""
echo "0. Prerequisites"
[[ -f "$CG" ]] && ok "churn-guard.sh found" || { fail "churn-guard.sh missing at $CG"; exit 1; }
if [[ -f "$CG_SRC" ]] && cmp -s "$CG_SRC" "$CG" 2>/dev/null; then
  ok "installed churn-guard.sh matches ai-toolbox source"
elif [[ -f "$CG_SRC" ]]; then
  fail "installed churn-guard.sh stale vs ai-toolbox source — run sync"
fi
bash -n "$CG" 2>/dev/null && ok "churn-guard.sh bash syntax valid" || fail "churn-guard.sh syntax error"

# ── temp control plane ──────────────────────────────────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/churn-test.XXXXXX")"
W="$TMP/work"
mkdir -p "$W/.orchestrate/logs" "$W/.orchestrate/tasks" "$W/.orchestrate/bin" \
  "$W/.orchestrate/inbox/processed"
cp "$CG" "$REQUEUE" "$W/.orchestrate/bin/" 2>/dev/null || true
CGW="$W/.orchestrate/bin/churn-guard.sh"

status_of() {
  local id="$1"
  awk -F'|' -v id="$id" '$0 ~ "\\| "id" \\|" { gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6; exit }' \
    "$W/.orchestrate/project.md"
}
malformed_rows() {
  awk -F'|' '/^\|[[:space:]]*[0-9A-Za-z]/ && $2 !~ /^[[:space:]]*ID[[:space:]]*$/ && $2 !~ /^-+$/ {
    t=$8; gsub(/[[:space:]]/,"",t); if (NF!=8 || t!="") c++ } END{print c+0}' \
    "$W/.orchestrate/project.md"
}

# ── Case A: task WITH a task file, driven through 3 increments ───────────────
ID=20260628-poison
cat > "$W/.orchestrate/tasks/$ID.md" <<EOF
# $ID — poison task
source: self
mode: auto
### Phase 1
status: pending
EOF
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $ID | poison task | auto | 1 | needs_human | 2026-01-01T00:00:00Z |
EOF

echo ""
echo "1. Counter increments on each requeue (task-file case)"
c1="$(bash "$CGW" cg_increment "$W" "$ID")"
c2="$(bash "$CGW" cg_increment "$W" "$ID")"
if [[ "$c1" == "1" && "$c2" == "2" ]]; then
  ok "increment 1,2 (task file + sidecar) — got $c1,$c2"
else
  fail "expected 1,2 — got $c1,$c2"
fi

echo ""
echo "2. requeue_count: line persisted in the task file"
if grep -qE '^requeue_count:[[:space:]]*2' "$W/.orchestrate/tasks/$ID.md"; then
  ok "task file carries requeue_count: 2"
else
  fail "requeue_count line missing/wrong: $(grep requeue_count "$W/.orchestrate/tasks/$ID.md" || echo none)"
fi

echo ""
echo "3. Below threshold (count=2): park_if_churned does NOT park"
if bash "$CGW" cg_park_if_churned "$W" "$ID" 2>/dev/null; then
  fail "parked at count=2 (should be below threshold 3)"
else
  ok "not parked below threshold"
fi
[[ "$(status_of "$ID")" == "needs_human" ]] && ok "registry still needs_human (untouched, not bypassed)" \
  || fail "registry status unexpectedly $(status_of "$ID")"
grep -q '^bypassed_at:' "$W/.orchestrate/tasks/$ID.md" && fail "bypass marker written too early" \
  || ok "no bypass marker yet (below threshold)"

echo ""
echo "4. 3rd cycle reaches threshold → parked as blocked"
c3="$(bash "$CGW" cg_increment "$W" "$ID")"
[[ "$c3" == "3" ]] && ok "increment reached 3" || fail "expected 3 — got $c3"
if bash "$CGW" cg_park_if_churned "$W" "$ID" 2>/dev/null; then
  ok "park_if_churned parked at threshold (returned 0)"
else
  fail "park_if_churned did NOT park at count=3"
fi
[[ "$(status_of "$ID")" == "needs_human" ]] && ok "registry forced to needs_human" \
  || fail "registry not needs_human: $(status_of "$ID")"
if grep -q '^bypassed_at:' "$W/.orchestrate/tasks/$ID.md" \
   && grep -qE '^bypass_reason:.*churn — re-processed 3×' "$W/.orchestrate/tasks/$ID.md"; then
  ok "bypassed_at: + bypass_reason: churn — re-processed 3× written"
else
  fail "bypass markers missing: $(grep -E '^(bypassed_at|bypass_reason):' "$W/.orchestrate/tasks/$ID.md" || echo none)"
fi

echo ""
echo "5. Investigation inbox job auto-filed (source:self, mode:auto, triggered_by)"
INV="$(ls "$W/.orchestrate/inbox/"investigate-churn-$ID-*.md 2>/dev/null | head -1)"
if [[ -n "$INV" ]] \
   && grep -qE '^source:[[:space:]]*self' "$INV" \
   && grep -qE '^mode:[[:space:]]*auto' "$INV" \
   && grep -qE "^triggered_by:[[:space:]]*$ID" "$INV"; then
  ok "investigation job filed with correct header"
else
  fail "investigation job missing/malformed: ${INV:-none}"
fi

echo ""
echo "6. Heartbeat carries the churn-guard blocked line"
if grep -qE "churn-guard — blocked $ID after 3 re-processings; filed investigate-churn-$ID" \
   "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "heartbeat blocked-line present"
else
  fail "heartbeat blocked-line missing: $(grep churn-guard "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null || echo none)"
fi

echo ""
echo "7. Second run does NOT double-file (dedup on triggered_by)"
before="$(ls "$W/.orchestrate/inbox/"investigate-churn-$ID-*.md 2>/dev/null | wc -l | tr -d ' ')"
bash "$CGW" cg_park_if_churned "$W" "$ID" >/dev/null 2>&1 || true
after="$(ls "$W/.orchestrate/inbox/"investigate-churn-$ID-*.md 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$before" == "1" && "$after" == "1" ]]; then
  ok "no double-file (before=$before after=$after)"
else
  fail "double-filed: before=$before after=$after"
fi

echo ""
echo "8. Registry NF==8 invariant preserved across park"
mr="$(malformed_rows)"
[[ "$mr" == "0" ]] && ok "0 malformed rows (NF==8 with empty trailing field)" \
  || fail "$mr malformed registry row(s) after park"

echo ""
echo "9. cg_reset (on complete) zeros the counter + clears requeue_count line"
bash "$CGW" cg_reset "$W" "$ID"
rc="$(bash "$CGW" cg_count "$W" "$ID")"
[[ "$rc" == "0" ]] && ok "counter reset to 0" || fail "counter not reset: $rc"
grep -q '^requeue_count:' "$W/.orchestrate/tasks/$ID.md" \
  && fail "requeue_count line still present after reset" \
  || ok "requeue_count line removed on reset"

# ── Case B: NO task file (ghost-reset auto job) — sidecar-only counter ───────
echo ""
echo "10. No-task-file (ghost) case: sidecar counter + park creates bypass file"
GID=20260628-ghost
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $GID | stalled auto job (no file) | auto | 1 | running | 2026-01-01T00:00:00Z |
EOF
g1="$(bash "$CGW" cg_increment "$W" "$GID")"
g2="$(bash "$CGW" cg_increment "$W" "$GID")"
g3="$(bash "$CGW" cg_increment "$W" "$GID")"
if [[ "$g1$g2$g3" == "123" ]]; then
  ok "ghost counter increments 1,2,3 via sidecar (no task file)"
else
  fail "ghost increments wrong: $g1,$g2,$g3"
fi
[[ ! -f "$W/.orchestrate/tasks/$GID.md" ]] && ok "no task file existed before park" \
  || fail "unexpected pre-existing ghost task file"
if bash "$CGW" cg_park_if_churned "$W" "$GID" 2>/dev/null; then
  ok "ghost parked at threshold"
else
  fail "ghost not parked at count=3"
fi
if [[ -f "$W/.orchestrate/tasks/$GID.md" ]] \
   && grep -qE '^bypass_reason:.*churn — re-processed 3×' "$W/.orchestrate/tasks/$GID.md"; then
  ok "park created a bypass task file for the ghost"
else
  fail "ghost bypass file missing/malformed"
fi
[[ "$(status_of "$GID")" == "needs_human" ]] && ok "ghost registry forced to needs_human" \
  || fail "ghost registry not needs_human: $(status_of "$GID")"
[[ -n "$(ls "$W/.orchestrate/inbox/"investigate-churn-$GID-*.md 2>/dev/null)" ]] \
  && ok "ghost investigation job filed" || fail "ghost investigation job missing"
[[ "$(malformed_rows)" == "0" ]] && ok "ghost park preserved NF==8 invariant" \
  || fail "ghost park broke invariant: $(malformed_rows) bad row(s)"

# ── Case C: end-to-end via requeue-unblocked.sh (real requeue site) ──────────
echo ""
echo "11. End-to-end: requeue-unblocked.sh parks after 3 re-queues (real site)"
EID=20260628-loop
cat > "$W/.orchestrate/tasks/$EID.md" <<EOF
# $EID — looping task
source: self
mode: auto
human_resolution: retry it
### Phase 1
status: pending
EOF
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $EID | looping task | auto | 1 | needs_human | 2026-01-01T00:00:00Z |
EOF
parked_cycle=0
for cyc in 1 2 3 4; do
  bash "$W/.orchestrate/bin/requeue-unblocked.sh" "$W" >/dev/null 2>&1 || true
  if [[ "$(status_of "$EID")" == "pending" ]]; then
    # re-block (simulate another failed run) so it re-queues next cycle
    sed -i '' "s/| $EID | looping task | auto | 1 | pending |/| $EID | looping task | auto | 1 | needs_human |/" \
      "$W/.orchestrate/project.md" 2>/dev/null || \
      sed -i "s/| $EID | looping task | auto | 1 | pending |/| $EID | looping task | auto | 1 | needs_human |/" \
      "$W/.orchestrate/project.md" 2>/dev/null || true
  fi
  if grep -q "churn-guard parked $EID" "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null && [[ "$parked_cycle" == "0" ]]; then
    parked_cycle="$cyc"
  fi
done
if [[ "$parked_cycle" == "3" ]]; then
  ok "requeue-unblocked.sh parked on the 3rd cycle (cycles 1-2 re-queued)"
else
  fail "park happened on cycle $parked_cycle (expected 3)"
fi
[[ "$(status_of "$EID")" == "needs_human" ]] && ok "final status needs_human (parked)" \
  || fail "final status $(status_of "$EID")"
einv="$(ls "$W/.orchestrate/inbox/"investigate-churn-$EID-*.md 2>/dev/null | wc -l | tr -d ' ')"
[[ "$einv" == "1" ]] && ok "exactly 1 investigation job filed (no double-file across cycles)" \
  || fail "expected 1 investigation file, got $einv"
[[ "$(malformed_rows)" == "0" ]] && ok "end-to-end preserved NF==8 invariant" \
  || fail "end-to-end broke invariant: $(malformed_rows) bad row(s)"

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED — see above" && exit 1
