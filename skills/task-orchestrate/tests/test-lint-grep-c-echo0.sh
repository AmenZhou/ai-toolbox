#!/usr/bin/env bash
# test-lint-grep-c-echo0.sh — regression fixture for task 20260731-inbox-FEB0
# (follow-up to 20260731-inbox-80C0).
#
# Background: `VAR="$(grep -c PATTERN FILE 2>/dev/null || echo 0)"` is a
# recurring bug pattern in this codebase — `grep -c` prints "0" to stdout AND
# exits 1 when FILE exists but has zero matching lines, so the `|| echo 0`
# fallback branch ALSO fires, and both "0"s land in the same command
# substitution (embedded-newline double-count, e.g. VAR becomes $'0\n0').
# This was fixed once already (20260726-inbox-*, test-stale-partial-progress-
# reset.sh) and then found again 4 more times across test-append-phase-log.sh,
# test-ghost-reset-stale-running.sh, test-phase-log-retry-label.sh, and
# test-requeue-orphaned-running.sh (task 20260731-inbox-80C0). The safe form is
# the two-line split: `VAR="$(grep -c PATTERN FILE 2>/dev/null || true)"` then
# `VAR="${VAR:-0}"`.
#
# This is a static lint check, not a runtime behavior test: it greps every
# .orchestrate/tests/*.sh and .orchestrate/bin/*.sh for the exact single-line
# `grep -c ... || echo 0` fallback pattern and fails if any live occurrence is
# found, so a future reintroduction of this bug class fails fast in CI instead
# of surfacing as a silent double-counted value at runtime.
set -uo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[[ -d "$PROJECT_ROOT/.orchestrate/bin" ]] || { echo "FATAL: $PROJECT_ROOT/.orchestrate/bin not found — PROJECT_ROOT path computation is broken (expected .../ai-console/.orchestrate/bin)" >&2; exit 1; }

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo ""
echo "── lint: grep -c ... || echo 0 double-count pattern — test suite ──"

echo ""
echo "1. No live occurrence of the buggy single-line 'grep -c ... || echo 0' pattern in .orchestrate/tests/*.sh or .orchestrate/bin/*.sh"
# Match only the actual bug shape — a command substitution assigning a
# fallback-to-echo-0 grep -c result, e.g. VAR="$(grep -c PATTERN FILE || echo 0)".
# This deliberately excludes comments/echo strings/suite descriptions that merely
# quote the pattern as documentation (this file's own docstring, run-tests.sh's
# suite label for this test, and the pre-existing explanatory comment in
# test-stale-partial-progress-reset.sh all do that and must NOT trip the check).
HITS="$(grep -rnE '\$\(grep -c .* \|\| echo 0\)' "$PROJECT_ROOT/.orchestrate/tests/"*.sh "$PROJECT_ROOT/.orchestrate/bin/"*.sh 2>/dev/null | grep -v '/test-lint-grep-c-echo0\.sh:' || true)"
if [[ -z "$HITS" ]]; then
  ok "no 'grep -c ... || echo 0' occurrences found"
else
  fail "found live 'grep -c ... || echo 0' double-count pattern(s):"$'\n'"$HITS"
fi

echo ""
echo "2. Negative case: a fixture file containing the buggy pattern is correctly flagged (confirms the check has teeth, not just a tautology)"
NEG_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$NEG_TMPDIR"' EXIT
mkdir -p "$NEG_TMPDIR/.orchestrate/tests" "$NEG_TMPDIR/.orchestrate/bin"
cat > "$NEG_TMPDIR/.orchestrate/tests/test-fixture-bad-pattern.sh" <<'EOF'
#!/usr/bin/env bash
COUNT="$(grep -c "foo" "$SOME_FILE" 2>/dev/null || echo 0)"
EOF
NEG_HITS="$(grep -rnE '\$\(grep -c .* \|\| echo 0\)' "$NEG_TMPDIR/.orchestrate/tests/"*.sh "$NEG_TMPDIR/.orchestrate/bin/"* 2>/dev/null || true)"
if [[ -n "$NEG_HITS" ]]; then
  ok "fixture file with the deliberately-reintroduced buggy pattern is correctly detected"
else
  fail "fixture file with the buggy pattern was NOT detected — the lint check would silently miss a real regression"
fi
rm -rf "$NEG_TMPDIR"
trap - EXIT

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  echo "  ALL TESTS PASSED"
  exit 0
else
  echo "  SOME TESTS FAILED — see above"
  exit 1
fi
