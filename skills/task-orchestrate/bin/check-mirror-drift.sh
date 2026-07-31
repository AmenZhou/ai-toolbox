#!/usr/bin/env bash
# check-mirror-drift.sh — report-only check for silent drift between the
# project-local .orchestrate/{bin,tests} scripts and their ai-toolbox
# skills/task-orchestrate/{bin,tests} mirror counterparts.
#
# Per SKILL.md's "Script-divergence" rule, each bin/test script has exactly
# two live copies: the ai-toolbox source and this project's copy. There is
# no third (~/.claude) mirror to check here.
#
# Not every file in .orchestrate/bin or .orchestrate/tests has an
# ai-toolbox counterpart — some are project-local only. Those are skipped
# silently (checked by existence, not reported as drift).
#
# This is REPORT-ONLY: it prints a WARN line for every drifted pair plus a
# final summary, then always exits 0. It never fails the suite — an
# in-progress, not-yet-mirrored edit is expected mid-cycle, not a bug.
# It exists so silent one-sided edits (e.g. rescue.sh's missing
# NO_FILE_GRACE_SECS guard and test-rescue.sh's missing test section, both
# found by hand in 20260717-inbox-C829) surface automatically going forward.
#
# Optional positional overrides (test hook, mirrors the $1=ROOT convention used
# by rescue.sh/update-registry-row.sh): $1 = PROJECT_ROOT (dir containing
# bin/ + tests/), $2 = TOOLBOX_ROOT (dir containing bin/ + tests/). Both default
# to the real locations when omitted, so production call sites are unaffected.
#
# Expect a persistently nonzero WARN count — this is NOT automatically a bug.
# (Investigated end-to-end by 20260731-inbox-08BD after being flagged as a
# recurring "21 drifted pairs" blocker by prior unrelated tasks.) Every tests/
# pair currently reported carries an irreducible STRUCTURAL component: ai-console
# nests scripts under .orchestrate/{bin,tests} (PROJECT_ROOT = two dirs up, refs
# "$PROJECT_ROOT/.orchestrate/bin/..."), while the ai-toolbox source tree keeps
# {bin,tests} as flat siblings under skills/task-orchestrate/ (PROJECT_ROOT = one
# dir up, refs "$PROJECT_ROOT/bin/..."). Those two PROJECT_ROOT lines can never be
# made byte-identical while the two trees keep this shape — diff -q will always
# flag the pair even after content is otherwise fully synced. (Confirmed by the
# ai-toolbox side's own code comment in tests/test-requeue-unblocked.sh, which
# independently documents the same rationale.)
#
# That said, do NOT treat "it's just the structural line" as a reason to stop
# reading each WARN — 08BD also found and fixed a real, non-structural gap
# layered on top: 19 of 21 ai-console test files were missing a FATAL
# PROJECT_ROOT-sanity guard ("[[ -d ... ]] || { echo FATAL ...; exit 1; }") that
# the ai-toolbox copies already had; backported ai-console-side (see 08BD's
# archive entry). Two further genuine content gaps — ai-toolbox's
# test-task-orchestrate.sh missing 5 session-attribution skill_has assertions,
# and its test-ghost-reset-stale-running.sh missing the DBBC (test 11)
# regression — were identified but deliberately NOT backported into ai-toolbox
# this round: both target files already carried a large, unrelated, pre-existing
# uncommitted diff in that repo (WIP from other in-flight tickets), and layering
# more edits on top of someone else's uncommitted WIP risks tangling unrelated
# changes into one commit. Re-check those two ai-toolbox files once that WIP
# lands/commits, then backport if still missing.
#
# Bottom line for future runs: always diff each WARN'd pair by hand. Expect the
# PROJECT_ROOT/bin-path line(s) to differ forever (structural, ignore); anything
# else that differs is a real candidate for either a mirroring fix or a fresh,
# specific note here — never bulk-suppress this script's output.

set -uo pipefail

PROJECT_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TOOLBOX_ROOT="${2:-/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate}"

DRIFTED=0
CHECKED=0

check_pair() {
  local project_dir="$1"
  local toolbox_dir="$2"
  local pattern="$3"

  local f base counterpart
  for f in "$project_dir"/$pattern; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    counterpart="$toolbox_dir/$base"
    [ -f "$counterpart" ] || continue
    CHECKED=$((CHECKED + 1))
    if ! diff -q "$f" "$counterpart" >/dev/null 2>&1; then
      DRIFTED=$((DRIFTED + 1))
      echo "  WARN: drifted — $f  vs  $counterpart"
    fi
  done
}

check_pair "$PROJECT_ROOT/bin" "$TOOLBOX_ROOT/bin" "*.sh"
check_pair "$PROJECT_ROOT/tests" "$TOOLBOX_ROOT/tests" "test-*.sh"

echo ""
if [ "$DRIFTED" -eq 0 ]; then
  echo "  0 drift — all mirrors in sync ($CHECKED pairs checked)"
else
  echo "  $DRIFTED drifted pair(s) found out of $CHECKED checked"
fi

exit 0
