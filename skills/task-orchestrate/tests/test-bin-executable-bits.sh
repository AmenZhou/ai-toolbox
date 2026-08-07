#!/usr/bin/env bash
# test-bin-executable-bits.sh — regression for task 20260726-inbox-D23C.
#
# Background: run-job.sh and rescue.sh gate several of their preflight helper
# calls on `[[ -x "$script" ]]` before running them (even though `bash "$script"`
# does not itself require the executable bit — several *other* helper calls in
# the same files correctly use `-f` instead, per rescue.sh's own comment: "Guard
# on -f (not -x): bash executes a script file without the executable bit set").
# For the scripts that ARE gated on -x, losing that bit doesn't error — it
# silently skips the call every cycle, with only a missing heartbeat line as
# evidence. This was caught live twice in one task (20260726-inbox-8CA8):
#   1. cleanup-stale-inbox.sh had lost its bit in the ai-toolbox source tree.
#   2. requeue-unblocked.sh had NEVER been executable in either the ai-toolbox
#      source tree OR the live deployed ai-console copy — its BC0E auto-requeue
#      feature had silently never run in production (zero heartbeat lines ever).
# This test asserts every -x-gated script stays executable in the ai-toolbox
# source tree, so a future bit-loss (e.g. from a raw `cp`/`awk > tmp && mv`
# rewrite, which does not preserve the original file's mode) fails fast in CI
# instead of silently degrading a live preflight step.
set -uo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
BIN="$PROJECT_ROOT/bin"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo ""
echo "── bin/ executable-bit invariant — test suite ─────"

# The exact set of scripts run-job.sh / rescue.sh gate on `[[ -x ]]` (not `-f`)
# before invoking, as of this test's authoring. If a future edit adds a new
# -x-gated call site, add it here too — that's the whole point of the test.
X_GATED_SCRIPTS=(
  finalize-completed-tasks.sh
  cleanup-stale-inbox.sh
  drain-inbox.sh
  tend-need-action.sh
  requeue-unblocked.sh
  run-job.sh
)

echo ""
echo "1. Every -x-gated helper script is executable in the ai-toolbox source tree"
for script in "${X_GATED_SCRIPTS[@]}"; do
  path="$BIN/$script"
  if [[ ! -f "$path" ]]; then
    fail "$script not found at $path"
  elif [[ -x "$path" ]]; then
    ok "$script is executable"
  else
    fail "$script is NOT executable ($path) — run-job.sh/rescue.sh's [[ -x ]] gate will silently skip it every cycle"
  fi
done

echo ""
echo "2. Negative case: a script missing +x is correctly flagged (confirms the check actually catches regressions, not just a tautology)"
NEG_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$NEG_TMPDIR"' EXIT
NEG_SCRIPT="$NEG_TMPDIR/not-executable.sh"
cp "$BIN/run-job.sh" "$NEG_SCRIPT"
chmod -x "$NEG_SCRIPT"
if [[ ! -x "$NEG_SCRIPT" ]]; then
  ok "fixture script with executable bit deliberately removed is correctly detected as NOT executable"
else
  fail "fixture script still reports executable after chmod -x — the -x check would silently miss a real regression"
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
