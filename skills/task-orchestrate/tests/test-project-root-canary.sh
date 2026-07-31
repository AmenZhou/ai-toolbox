#!/usr/bin/env bash
# test-project-root-canary.sh — regression for the "PROJECT_ROOT computation
# hard-codes ai-console's deployed layout" bug class (20260731-inbox-DAA1/29F8).
#
# Background: task-orchestrate test files are mirrored in two places with two
# different — and both individually correct — PROJECT_ROOT depths:
#   - ai-toolbox source:  skills/task-orchestrate/tests/test-*.sh
#                         → one level up lands on skills/task-orchestrate/,
#                           so bin/ scripts live at "$PROJECT_ROOT/bin/...".
#   - ai-console deployed: .orchestrate/tests/test-*.sh
#                         → two levels up lands on the ai-console project
#                           root, so bin/ scripts live at
#                           "$PROJECT_ROOT/.orchestrate/bin/...".
# A test file is broken for standalone ai-toolbox use if its PROJECT_ROOT
# derivation still expects the ai-console shape (i.e. reaches for
# "$PROJECT_ROOT/.orchestrate/...") while living in the ai-toolbox source
# tree. This exact class of bug shipped twice:
#   - test-finalize-completed-tasks.sh (fixed in 25a380f, 20260731-inbox-DAA1)
#   - test-requeue-unblocked.sh (fixed in the 29F8 follow-up)
# Both FATALed/exited immediately when run standalone from ai-toolbox.
#
# test-task-orchestrate.sh is a deliberate, documented exception: it asserts
# against the real deployed ai-console control plane (SKILL.md install sync,
# launchd plists, live .orchestrate/project.md) and says so explicitly in its
# header ("Run from the ai-console project root"). This canary treats that
# marker as the only valid opt-out — any other file that reaches for
# "$PROJECT_ROOT/.orchestrate/..." without declaring itself ai-console-only
# is presumed broken for standalone ai-toolbox use.
#
# This is a static/grep-only check (no test execution, no side effects) —
# cheap enough to run on every suite invocation.
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo ""
echo "── PROJECT_ROOT standalone-safety canary — test suite ───"
echo ""
echo "1. \$PROJECT_ROOT/.orchestrate reference requires explicit ai-console-only marker"

shopt -s nullglob
for f in "$SCRIPT_DIR"/test-*.sh; do
  base="$(basename "$f")"
  [[ "$base" == "test-project-root-canary.sh" ]] && continue

  if grep -q 'PROJECT_ROOT/\.orchestrate' "$f"; then
    if grep -qF "ai-console project root" "$f"; then
      ok "$base references \$PROJECT_ROOT/.orchestrate but declares itself ai-console-only"
    else
      fail "$base references \$PROJECT_ROOT/.orchestrate without an ai-console-only marker — likely FATALs standalone from ai-toolbox (see test-finalize-completed-tasks.sh / test-requeue-unblocked.sh history)"
    fi
  fi
done
shopt -u nullglob

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"

if [[ "$FAIL" -eq 0 ]]; then
  echo "  ALL TESTS PASSED"
  exit 0
else
  echo "  TESTS FAILED"
  exit 1
fi
