#!/usr/bin/env bash
# test-phase-log-retry-label.sh — regression for task 20260720-inbox-69E3.
#
# Background: .orchestrate/logs/20260719-inbox-TSDF-phase1.log shows a
# raw-text fallback entry (no "## PHASE OUTPUT" marker — the documented
# agent-phase fallback, see test-append-phase-log.sh Section D) followed by a
# retry entry that is NOT labeled "(retry N)", even though it is clearly a
# second attempt at the same phase number. Root cause: append-phase-log.sh
# trusted the caller's $RETRIES argument as the sole source of truth for the
# "(retry N)" label. SKILL.md's Step C ("increment retries") is prose the
# calling LLM session must track itself turn-to-turn; if that tracking is
# lost or reset (e.g. across a fresh turn after a markerless fallback
# attempt), the next call for the same phase N arrives with RETRIES=0 again
# and the header silently repeats plain "Phase N" instead of labeling the
# retry.
#
# Fix asserted here: append-phase-log.sh now auto-derives the retry number
# from "=== Phase N " headers already present in that phase's log file and
# uses max(existing_count, caller's $RETRIES) — so a caller that fails to
# track/pass the correct RETRIES value can no longer produce a mislabeled
# retry. This suite mirrors test-t4-claim-not-wait.sh's mk_root() fixture
# style: build a minimal mock .orchestrate/ control plane, drive the real
# append-phase-log.sh against it, and assert on the resulting log file
# content — no mocking of the script under test itself.
set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
APPEND_SCRIPT="${APPEND_SCRIPT:-$PROJECT_ROOT/bin/append-phase-log.sh}"

REAL_BODY='## PHASE OUTPUT
files_changed: none
summary: real phase output on the second attempt
confidence: high
blockers: none
acceptance_criteria_met: [✓ a | ✓ b]
test_evidence: n/a (synthetic test fixture)'

# mk_root — builds a fresh mock .orchestrate/ control plane, echoes its path.
mk_root() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/.orchestrate/tasks" "$tmp/.orchestrate/logs"
  echo "$tmp"
}

echo ""
echo "── phase-log retry labeling after a markerless first attempt (20260720-inbox-69E3) ───"

[[ -f "$APPEND_SCRIPT" ]] && ok "append-phase-log.sh present" || fail "append-phase-log.sh missing at $APPEND_SCRIPT"

echo ""
echo "1. THE regression: markerless (raw-text) first attempt at RETRIES=0, then a real second"
echo "   attempt ALSO called with RETRIES=0 (simulating a caller that lost its retry-tracking"
echo "   across turns) -- the second entry must still be labeled '(retry 1)', not plain 'Phase 1'"
ROOT="$(mk_root)"
ID="20260720-tst"
printf 'I attempted the phase but could not produce a PHASE OUTPUT block.\n' \
  | bash "$APPEND_SCRIPT" "$ROOT" "$ID" "1" "Sample Phase" "0" >/dev/null 2>&1
printf '%s\n' "$REAL_BODY" \
  | bash "$APPEND_SCRIPT" "$ROOT" "$ID" "1" "Sample Phase" "0" >/dev/null 2>&1
LOG="$ROOT/.orchestrate/logs/${ID}-phase1.log"
[[ -f "$LOG" ]] && ok "phase log file exists" || fail "phase log file missing"
grep -q '^=== Phase 1 —' "$LOG" 2>/dev/null && ok "first attempt header present, unlabeled (correctly, it IS attempt 1)" || fail "first attempt header missing/malformed"
grep -q '^\[no PHASE OUTPUT block' "$LOG" 2>/dev/null && ok "first attempt logged as a raw-text fallback (no marker)" || fail "first attempt fallback marker missing"
grep -q '^=== Phase 1 (retry 1) —' "$LOG" 2>/dev/null && ok "second attempt auto-labeled '(retry 1)' despite caller passing RETRIES=0 -- THE FIX" || fail "second attempt NOT labeled '(retry 1)' -- this is the 69E3 bug shape"
grep -q '^## PHASE OUTPUT' "$LOG" 2>/dev/null && ok "second attempt's real PHASE OUTPUT body present" || fail "second attempt's PHASE OUTPUT body missing"
grep -q 'real phase output on the second attempt' "$LOG" 2>/dev/null && ok "second attempt's summary content preserved" || fail "second attempt's summary content missing"
rm -rf "$ROOT"

echo ""
echo "2. A correctly-tracking caller (explicit RETRIES=1) gets the same label -- auto-derivation"
echo "   does not conflict with a caller that DID track its retries correctly"
ROOT="$(mk_root)"
ID="20260720-tst2"
printf 'raw fallback text, no marker\n' \
  | bash "$APPEND_SCRIPT" "$ROOT" "$ID" "1" "Sample Phase" "0" >/dev/null 2>&1
printf '%s\n' "$REAL_BODY" \
  | bash "$APPEND_SCRIPT" "$ROOT" "$ID" "1" "Sample Phase" "1" >/dev/null 2>&1
LOG="$ROOT/.orchestrate/logs/${ID}-phase1.log"
RETRY_HDRS="$(grep -c '^=== Phase 1 (retry 1) —' "$LOG" 2>/dev/null || true)"
RETRY_HDRS="${RETRY_HDRS:-0}"
[[ "$RETRY_HDRS" -eq 1 ]] && ok "explicit RETRIES=1 still produces exactly one '(retry 1)' header (no double-counting)" || fail "expected exactly 1 '(retry 1)' header, found $RETRY_HDRS"
rm -rf "$ROOT"

echo ""
echo "3. Three attempts at the same phase (2 markerless fallbacks then a real one) -- labels"
echo "   climb monotonically: Phase 2, Phase 2 (retry 1), Phase 2 (retry 2)"
ROOT="$(mk_root)"
ID="20260720-tst3"
printf 'fallback attempt one, no marker\n' \
  | bash "$APPEND_SCRIPT" "$ROOT" "$ID" "2" "Multi-retry Phase" "0" >/dev/null 2>&1
printf 'fallback attempt two, still no marker\n' \
  | bash "$APPEND_SCRIPT" "$ROOT" "$ID" "2" "Multi-retry Phase" "0" >/dev/null 2>&1
printf '%s\n' "$REAL_BODY" \
  | bash "$APPEND_SCRIPT" "$ROOT" "$ID" "2" "Multi-retry Phase" "0" >/dev/null 2>&1
LOG="$ROOT/.orchestrate/logs/${ID}-phase2.log"
grep -q '^=== Phase 2 —' "$LOG" 2>/dev/null && ok "attempt 1 header unlabeled" || fail "attempt 1 header missing/malformed"
grep -q '^=== Phase 2 (retry 1) —' "$LOG" 2>/dev/null && ok "attempt 2 header labeled '(retry 1)'" || fail "attempt 2 header not labeled '(retry 1)'"
grep -q '^=== Phase 2 (retry 2) —' "$LOG" 2>/dev/null && ok "attempt 3 (the real one) header labeled '(retry 2)'" || fail "attempt 3 header not labeled '(retry 2)'"
TOTAL_HDRS="$(grep -c '^=== Phase 2' "$LOG" 2>/dev/null || true)"
TOTAL_HDRS="${TOTAL_HDRS:-0}"
[[ "$TOTAL_HDRS" -eq 3 ]] && ok "all 3 attempts preserved (no overwrite)" || fail "expected 3 headers total, found $TOTAL_HDRS"
rm -rf "$ROOT"

echo ""
echo "4. Different phase numbers in the same log-file family do not cross-contaminate retry counts"
echo "   (Phase 1 markerless fallback must not bump Phase 2's retry label)"
ROOT="$(mk_root)"
ID="20260720-tst4"
printf 'phase 1 markerless fallback\n' \
  | bash "$APPEND_SCRIPT" "$ROOT" "$ID" "1" "Phase One" "0" >/dev/null 2>&1
printf '%s\n' "$REAL_BODY" \
  | bash "$APPEND_SCRIPT" "$ROOT" "$ID" "2" "Phase Two" "0" >/dev/null 2>&1
LOG2="$ROOT/.orchestrate/logs/${ID}-phase2.log"
grep -q '^=== Phase 2 —' "$LOG2" 2>/dev/null && ! grep -q 'retry' "$LOG2" 2>/dev/null && ok "Phase 2's first attempt correctly unlabeled -- Phase 1's fallback did not leak in (separate log files)" || fail "Phase 2 unexpectedly labeled as a retry"
rm -rf "$ROOT"

echo ""
echo "── phase-log retry labeling: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
