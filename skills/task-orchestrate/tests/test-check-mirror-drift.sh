#!/usr/bin/env bash
# test-check-mirror-drift.sh — regression for task 20260717-inbox-3CCD's
# check-mirror-drift.sh (report-only mirror-drift sweep between
# .orchestrate/{bin,tests} and the ai-toolbox skills/task-orchestrate
# {bin,tests} counterparts).
#
# check-mirror-drift.sh takes optional positional overrides ($1=PROJECT_ROOT,
# $2=TOOLBOX_ROOT, both defaulting to the real locations) added by this task
# specifically so it can be pointed at controlled fixture directories instead
# of the real ai-toolbox checkout. This suite drives it against fixture
# PROJECT_ROOT/TOOLBOX_ROOT trees and asserts:
#   - a matched (identical) pair produces NO WARN line for that file
#   - a deliberately-diverged pair DOES produce a WARN line for that file
#   - a project-local-only file (no counterpart) is skipped silently
#   - the script always exits 0 (report-only, never fails the suite)
set -uo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
DRIFT="${DRIFT:-$PROJECT_ROOT/bin/check-mirror-drift.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

echo ""
echo "── check-mirror-drift.sh — test suite ───"

echo ""
echo "0. Prerequisites"
[[ -f "$DRIFT" ]] && ok "check-mirror-drift.sh found" || { fail "check-mirror-drift.sh missing at $DRIFT"; exit 1; }
bash -n "$DRIFT" 2>/dev/null && ok "check-mirror-drift.sh bash syntax valid" || fail "check-mirror-drift.sh syntax error"

# ── fixture PROJECT_ROOT / TOOLBOX_ROOT trees ────────────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mirror-drift-test.XXXXXX")"
FPROJ="$TMP/proj"
FBOX="$TMP/toolbox"
mkdir -p "$FPROJ/bin" "$FPROJ/tests" "$FBOX/bin" "$FBOX/tests"

# Matched (non-drifted) bin pair.
printf '#!/usr/bin/env bash\necho matched\n' > "$FPROJ/bin/matched-script.sh"
cp "$FPROJ/bin/matched-script.sh" "$FBOX/bin/matched-script.sh"

# Deliberately-diverged bin pair.
printf '#!/usr/bin/env bash\necho v1\n' > "$FPROJ/bin/diverged-script.sh"
printf '#!/usr/bin/env bash\necho v2 — edited only on one side\n' > "$FBOX/bin/diverged-script.sh"

# Matched test-*.sh pair.
printf '#!/usr/bin/env bash\necho matched test\n' > "$FPROJ/tests/test-matched.sh"
cp "$FPROJ/tests/test-matched.sh" "$FBOX/tests/test-matched.sh"

# Deliberately-diverged test-*.sh pair.
printf '#!/usr/bin/env bash\necho test v1\n' > "$FPROJ/tests/test-diverged.sh"
printf '#!/usr/bin/env bash\necho test v2 — edited only on one side\n' > "$FBOX/tests/test-diverged.sh"

# Project-local-only file (no ai-toolbox counterpart) — must be skipped silently,
# not reported as drift.
printf '#!/usr/bin/env bash\necho local only\n' > "$FPROJ/bin/local-only.sh"

echo ""
echo "1. Run against fixtures — capture output"
OUT="$(bash "$DRIFT" "$FPROJ" "$FBOX" 2>&1)"
RC=$?
echo "$OUT" | sed 's/^/    /'

echo ""
echo "2. Matched pair produces no WARN line"
if ! echo "$OUT" | grep -q "matched-script.sh"; then
  ok "matched-script.sh not mentioned in output (no drift reported)"
else
  fail "matched-script.sh unexpectedly appears in output: $(echo "$OUT" | grep matched-script.sh)"
fi
if ! echo "$OUT" | grep -q "test-matched.sh"; then
  ok "test-matched.sh not mentioned in output (no drift reported)"
else
  fail "test-matched.sh unexpectedly appears in output: $(echo "$OUT" | grep test-matched.sh)"
fi

echo ""
echo "3. Diverged pair produces a WARN line naming that file"
if echo "$OUT" | grep -qE "WARN: drifted.*diverged-script\.sh"; then
  ok "WARN line printed for diverged-script.sh"
else
  fail "no WARN line for diverged-script.sh: $OUT"
fi
if echo "$OUT" | grep -qE "WARN: drifted.*test-diverged\.sh"; then
  ok "WARN line printed for test-diverged.sh"
else
  fail "no WARN line for test-diverged.sh: $OUT"
fi

echo ""
echo "4. Project-local-only file (no counterpart) is skipped silently"
if ! echo "$OUT" | grep -q "local-only.sh"; then
  ok "local-only.sh not mentioned in output (skipped, not reported)"
else
  fail "local-only.sh unexpectedly appears in output: $(echo "$OUT" | grep local-only.sh)"
fi

echo ""
echo "5. Summary line reports exactly 2 drifted pairs out of 4 checked"
if echo "$OUT" | grep -qE "2 drifted pair\(s\) found out of 4 checked"; then
  ok "summary line: 2 drifted / 4 checked"
else
  fail "unexpected summary line: $(echo "$OUT" | tail -3)"
fi

echo ""
echo "6. Script exits 0 even with drifted pairs present (report-only)"
[[ "$RC" -eq 0 ]] && ok "exit code 0 with drift present" || fail "exit code $RC (expected 0)"

echo ""
echo "7. All-matched fixture set (no drift) still exits 0 and reports 0 drifted"
CLEAN_PROJ="$TMP/proj-clean"
CLEAN_BOX="$TMP/toolbox-clean"
mkdir -p "$CLEAN_PROJ/bin" "$CLEAN_PROJ/tests" "$CLEAN_BOX/bin" "$CLEAN_BOX/tests"
printf '#!/usr/bin/env bash\necho clean\n' > "$CLEAN_PROJ/bin/clean-script.sh"
cp "$CLEAN_PROJ/bin/clean-script.sh" "$CLEAN_BOX/bin/clean-script.sh"
CLEAN_OUT="$(bash "$DRIFT" "$CLEAN_PROJ" "$CLEAN_BOX" 2>&1)"
CLEAN_RC=$?
if [[ "$CLEAN_RC" -eq 0 ]]; then
  ok "exit code 0 with no drift present"
else
  fail "exit code $CLEAN_RC (expected 0) on all-matched fixture set"
fi
if echo "$CLEAN_OUT" | grep -qE "0 drift — all mirrors in sync \(1 pairs? checked\)"; then
  ok "summary line: 0 drift — all mirrors in sync (1 pair checked)"
else
  fail "unexpected clean-run summary line: $(echo "$CLEAN_OUT" | tail -3)"
fi

echo ""
echo "8. Default invocation (no args) still resolves against the real project + ai-toolbox trees"
if bash -n "$DRIFT" 2>/dev/null; then
  DEFAULT_OUT="$(bash "$DRIFT" 2>&1)"
  DEFAULT_RC=$?
  [[ "$DEFAULT_RC" -eq 0 ]] && ok "default (no-arg) invocation exits 0" \
    || fail "default invocation exited $DEFAULT_RC (expected 0)"
  echo "$DEFAULT_OUT" | grep -qE "checked\)?$" && ok "default invocation prints a summary line" \
    || fail "default invocation missing summary line: $DEFAULT_OUT"
else
  fail "syntax check failed, skipping default invocation"
fi

echo ""
echo "── check-mirror-drift.sh: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
