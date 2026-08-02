#!/usr/bin/env bash
# test-check-depends-on.sh — unit tests for .orchestrate/bin/check-depends-on.sh
# (DEP-TEND-IMPL, reports/orchestrate/dep-tend-inv_plan.md §2).
#
# check-depends-on.sh wraps run-job.sh's cross_task_depends_on_blocked()
# (CROSS-2, 20260727-inbox-7D4A) as a standalone, directly-invokable script
# for the single-ID dispatch paths that skip T-4 entirely and therefore never
# reach mark_pending_tasks_as_running()'s bulk pre-dispatch gate:
#   1. `tend go auto <ID>` (SKILL.md "Mode `tend go auto <ID>`")
#   2. human/dashboard `go`/`go auto` approval of an `awaiting_go` row
#      (SKILL.md "## On \"go\" / \"go auto\"")
#
# Reuses the exact fixture shape proven in test-run-job.sh §18 (CROSS-2),
# but calls the new standalone script directly per-ID instead of the bulk
# mark_pending_tasks_as_running() sweep — this is the previously-uncovered
# single-ID path the audit (DEP-TEND-INV) found had no check at all.
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
CHECK_SCRIPT="${CHECK_SCRIPT:-$PROJECT_ROOT/bin/check-depends-on.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

[[ -x "$CHECK_SCRIPT" ]] || fail "check-depends-on.sh missing or not executable at $CHECK_SCRIPT"

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT

echo "1. check-depends-on.sh <ROOT> <ID> — CROSS-2 fixture shape reused from"
echo "   test-run-job.sh §18, invoked as the single-ID gate directly"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-depends-on-test.XXXXXX")"
mkdir -p "$TMP/.orchestrate/tasks"
PROJ="$TMP/.orchestrate/project.md"
cat > "$PROJ" << 'PEOF'
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| 20260727-inbox-BB01 | CROSS-2 blocker (gated, awaiting_go) | gated | 1 | awaiting_go |  |
| 20260727-inbox-BB02 | CROSS-2 blocker (auto, still pending) | auto | 1 | pending |  |
| 20260727-inbox-BB03 | CROSS-2 blocker (auto, complete) | auto | 1 | complete |  |
| 20260727-inbox-DD01 | CROSS-2 dependent — blocked by gated blocker | auto | 1 | pending |  |
| 20260727-inbox-DD02 | CROSS-2 dependent — blocked by pending blocker | auto | 1 | pending |  |
| 20260727-inbox-DD03 | CROSS-2 dependent — blocker already complete | auto | 1 | pending |  |
| 20260727-inbox-DD04 | CROSS-2 dependent — same-file phase-number depends_on | auto | 1 | pending |  |
| 20260727-inbox-DD05 | CROSS-2 dependent — depends_on: none | auto | 1 | pending |  |
PEOF
printf 'id: 20260727-inbox-DD01\ndepends_on: 20260727-inbox-BB01\n' > "$TMP/.orchestrate/tasks/20260727-inbox-DD01.md"
printf 'id: 20260727-inbox-DD02\ndepends_on: 20260727-inbox-BB02\n' > "$TMP/.orchestrate/tasks/20260727-inbox-DD02.md"
printf 'id: 20260727-inbox-DD03\ndepends_on: 20260727-inbox-BB03\n' > "$TMP/.orchestrate/tasks/20260727-inbox-DD03.md"
printf 'id: 20260727-inbox-DD04\ndepends_on: 1\n' > "$TMP/.orchestrate/tasks/20260727-inbox-DD04.md"
printf 'id: 20260727-inbox-DD05\ndepends_on: none\n' > "$TMP/.orchestrate/tasks/20260727-inbox-DD05.md"

run_check() {
  # Capture both stdout and exit code without letting either the "blocked"
  # (exit 0) or "clear" (exit 1) case trip this suite's own set -e.
  local id="$1"
  local out rc=0
  out="$(bash "$CHECK_SCRIPT" "$TMP" "$id")" || rc=$?
  printf 'EXIT:%d\n%s\n' "$rc" "$out"
}

OUT_DD01="$(run_check 20260727-inbox-DD01)"
if echo "$OUT_DD01" | grep -qF "EXIT:0" && echo "$OUT_DD01" | grep -qF "20260727-inbox-BB01" && echo "$OUT_DD01" | grep -qF "awaiting_go"; then
  ok "blocked-by-gated fixture (DD01): exit 0, prints blocker ID + awaiting_go status"
else
  fail "blocked-by-gated fixture (DD01) did not report blocked as expected: $OUT_DD01"
fi

OUT_DD02="$(run_check 20260727-inbox-DD02)"
if echo "$OUT_DD02" | grep -qF "EXIT:0" && echo "$OUT_DD02" | grep -qF "20260727-inbox-BB02" && echo "$OUT_DD02" | grep -qF "pending"; then
  ok "blocked-by-pending fixture (DD02): exit 0, prints blocker ID + pending status"
else
  fail "blocked-by-pending fixture (DD02) did not report blocked as expected: $OUT_DD02"
fi

OUT_DD03="$(run_check 20260727-inbox-DD03)"
if echo "$OUT_DD03" | grep -qF "EXIT:1"; then
  ok "blocked-by-complete fixture (DD03): exit 1 (clear — blocker already complete)"
else
  fail "blocked-by-complete fixture (DD03) wrongly reported blocked: $OUT_DD03"
fi

OUT_DD04="$(run_check 20260727-inbox-DD04)"
if echo "$OUT_DD04" | grep -qF "EXIT:1"; then
  ok "same-file phase-number depends_on fixture (DD04): exit 1 (clear — not a registry-ID shape)"
else
  fail "same-file phase-number depends_on fixture (DD04) wrongly reported blocked: $OUT_DD04"
fi

OUT_DD05="$(run_check 20260727-inbox-DD05)"
if echo "$OUT_DD05" | grep -qF "EXIT:1"; then
  ok "depends_on: none fixture (DD05): exit 1 (clear)"
else
  fail "depends_on: none fixture (DD05) wrongly reported blocked: $OUT_DD05"
fi

# Edge case: ID with no task file at all (e.g. a stub not yet written) — must
# not error out, must report clear (nothing to block on).
OUT_MISSING="$(run_check 20260727-inbox-ZZZZ)"
if echo "$OUT_MISSING" | grep -qF "EXIT:1"; then
  ok "missing task file: exit 1 (clear — no depends_on: info to block on)"
else
  fail "missing task file case did not exit 1 as expected: $OUT_MISSING"
fi

rm -rf "$TMP"
TMP=""

echo ""
echo "2. Bypass regression: single-ID dispatch (\`tend go auto <ID>\` /"
echo "   human-or-dashboard \`go auto <ID>\` approval) must not flip a"
echo "   depends_on:-blocked row to running, and must log the same skip"
echo "   heartbeat format mark_pending_tasks_as_running() uses. This is the"
echo "   exact gap DEP-TEND-INV found: these entry points skip T-4 (and thus"
echo "   the CROSS-2 gate) entirely — before DEP-TEND-IMPL, nothing blocked them."

TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-depends-on-bypass.XXXXXX")"
mkdir -p "$TMP/.orchestrate/tasks"
PROJ="$TMP/.orchestrate/project.md"
HB="$TMP/hb.log"
cat > "$PROJ" << 'PEOF'
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| 20260801-inbox-BEEF | single-ID bypass blocker (pending) | auto | 1 | pending |  |
| 20260801-inbox-DEAD | single-ID dispatch target — blocked | auto | 1 | pending |  |
| 20260801-inbox-CAFE | single-ID dispatch target — clear | auto | 1 | pending |  |
PEOF
printf 'id: 20260801-inbox-DEAD\ndepends_on: 20260801-inbox-BEEF\n' > "$TMP/.orchestrate/tasks/20260801-inbox-DEAD.md"
printf 'id: 20260801-inbox-CAFE\ndepends_on: none\n' > "$TMP/.orchestrate/tasks/20260801-inbox-CAFE.md"

row_status() {
  awk -F'|' -v id="$1" '$0 ~ ("\\| " id " \\|") { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$6); print $6; exit }' "$PROJ"
}
flip_to_running() {
  local id="$1"
  awk -F'|' -v id="$id" 'BEGIN{OFS="|"} $0 ~ ("\\| " id " \\|") { $6=" running "; } { print }' "$PROJ" > "$PROJ.tmp" && mv "$PROJ.tmp" "$PROJ"
}

# Simulate the documented "Mode `tend go auto <ID>`" / "go auto <ID>"
# protocol exactly as SKILL.md now specifies it: run check-depends-on.sh
# before touching the task file; blocked => leave row as-is + log skip line;
# clear => proceed (here: flip to running, standing in for "run the full
# auto execution loop").
dispatch_single_id() {
  local id="$1"
  local block_info="" rc=0
  block_info="$(bash "$CHECK_SCRIPT" "$TMP" "$id")" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    local dep dep_status
    dep="${block_info%%$'\t'*}"
    dep_status="${block_info#*$'\t'}"
    if [[ "$dep_status" == "awaiting_go" ]]; then
      echo "tend-auto — skip dispatch ${id}: depends_on ${dep} is gated/awaiting_go (needs human go on ${dep} before ${id} can run)" >> "$HB"
    else
      echo "tend-auto — skip dispatch ${id}: depends_on ${dep} not complete (status: ${dep_status})" >> "$HB"
    fi
    return 0
  fi
  flip_to_running "$id"
  echo "tend-auto — dispatching \"single-ID target\" (${id})" >> "$HB"
  return 0
}

dispatch_single_id 20260801-inbox-DEAD
dispatch_single_id 20260801-inbox-CAFE

if [[ "$(row_status 20260801-inbox-DEAD)" == "pending" ]]; then
  ok "DEAD (blocked by pending BEEF): single-ID dispatch did NOT flip row to running"
else
  fail "DEAD was wrongly flipped to running despite an incomplete depends_on: blocker (status: $(row_status 20260801-inbox-DEAD)) — this is exactly the DEP-TEND-INV gap"
fi
if grep -qF "skip dispatch 20260801-inbox-DEAD" "$HB" 2>/dev/null && grep -qF "20260801-inbox-BEEF" "$HB" 2>/dev/null; then
  ok "DEAD skip is logged naming the blocker (20260801-inbox-BEEF), same heartbeat format as the batch path"
else
  fail "no skip heartbeat line found for DEAD: $(cat "$HB" 2>/dev/null)"
fi

if [[ "$(row_status 20260801-inbox-CAFE)" == "running" ]]; then
  ok "CAFE (depends_on: none): single-ID dispatch proceeds normally, row flipped to running"
else
  fail "CAFE was wrongly withheld despite depends_on: none (status: $(row_status 20260801-inbox-CAFE))"
fi

rm -rf "$TMP"
TMP=""

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED — see above" && exit 1
