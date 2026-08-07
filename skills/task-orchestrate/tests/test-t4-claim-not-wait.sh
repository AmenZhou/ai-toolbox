#!/usr/bin/env bash
# test-t4-claim-not-wait.sh — regression for the T-4 "running tasks with no
# task file — claim, don't wait" rule (RS01 dispatch-starvation fix,
# 20260719-inbox-25CD), plus its documented residual lock-bypass race note
# (20260719-inbox-DF77).
#
# Background: the T-4 scan step itself is LLM-driven (SKILL.md prose, not a
# bash script) — a live agent session reads the registry and decides whether
# a `running` row is its own unclaimed work or a genuinely in-progress
# sibling task. There is no reusable bin/ script implementing that
# classification (unlike the 3C1D bash backstop in
# requeue-orphaned-running.sh, which mirrors it deterministically for the
# "no agent session ran at all this cycle" case). Per SKILL.md's documented
# rule, the classification is purely structural:
#
#   running row + NO task file + NO dispatch heartbeat line  -> unclaimed,
#     claim now (fold into this session's own pending-task batch)
#   running row + task file exists                            -> in progress,
#     skip
#   running row + dispatch heartbeat line exists (no task file yet) -> in
#     progress, skip
#
# This test exercises that structural precondition-detection logic directly
# (is_unclaimed_running_row(), inlined below as the thing under test — see
# test-requeue-orphaned-running.sh for the equivalent bash-script-under-test
# pattern; here the "script" IS the classification rule since no bin/
# script owns it) against mock .orchestrate/ fixtures, so a future edit to
# the no-file/no-heartbeat detection logic (e.g. mirrored into any future
# bin/ helper) has a concrete regression to break instead of only a
# skill_has() prose grep against SKILL.md's wording.
set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# is_unclaimed_running_row <ROOT> <ID>
# Mirrors SKILL.md's T-4 "claim, don't wait" structural precondition check:
# echoes "unclaimed" if the row is running with no task file and no dispatch
# heartbeat line for <ID>; echoes "in-progress" otherwise. Caller is
# responsible for having already confirmed the registry row status is
# `running` (this helper only checks the task-file/heartbeat half of the
# rule, same division of labor as the real T-4 scan: status filter first,
# then this check).
is_unclaimed_running_row() {
  local root="$1" id="$2"
  local task_file="$root/.orchestrate/tasks/${id}.md"
  local heartbeat="$root/.orchestrate/logs/heartbeat.log"

  if [[ -f "$task_file" ]]; then
    echo "in-progress"
    return
  fi
  if [[ -f "$heartbeat" ]] && grep -q "tend-auto — dispatching \".*\" (${id})" "$heartbeat"; then
    echo "in-progress"
    return
  fi
  echo "unclaimed"
}

# mk_root — builds a fresh mock .orchestrate/ control plane, echoes its path.
mk_root() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/.orchestrate/tasks" "$tmp/.orchestrate/logs"
  echo "$tmp"
}

echo ""
echo "── T-4 claim-not-wait — structural classification test suite ───"

echo ""
echo "1. running + no task file + no heartbeat line -> unclaimed (claim now)"
ROOT="$(mk_root)"
r="$(is_unclaimed_running_row "$ROOT" "20260719-tst")"
[[ "$r" == "unclaimed" ]] && ok "classified unclaimed — RS01 claim-now path" || fail "classified '$r' (expected unclaimed)"
rm -rf "$ROOT"

echo ""
echo "2. running + task file present -> in-progress (skip, sibling batch owns it)"
ROOT="$(mk_root)"
printf '# Task\nid: 20260719-tst\n' > "$ROOT/.orchestrate/tasks/20260719-tst.md"
r="$(is_unclaimed_running_row "$ROOT" "20260719-tst")"
[[ "$r" == "in-progress" ]] && ok "classified in-progress — task file present" || fail "classified '$r' (expected in-progress)"
rm -rf "$ROOT"

echo ""
echo "3. running + dispatch heartbeat line present, no task file yet -> in-progress (skip)"
ROOT="$(mk_root)"
echo "[2026-07-19T00:00:00Z] tend-auto — dispatching \"a job\" (20260719-tst) [batch 1]" >> "$ROOT/.orchestrate/logs/heartbeat.log"
r="$(is_unclaimed_running_row "$ROOT" "20260719-tst")"
[[ "$r" == "in-progress" ]] && ok "classified in-progress — dispatch heartbeat line present" || fail "classified '$r' (expected in-progress)"
rm -rf "$ROOT"

echo ""
echo "4. running + heartbeat log exists but has no matching dispatch line for this ID -> unclaimed"
ROOT="$(mk_root)"
echo "[2026-07-19T00:00:00Z] tend-auto — dispatching \"a different job\" (20260719-other) [batch 1]" >> "$ROOT/.orchestrate/logs/heartbeat.log"
r="$(is_unclaimed_running_row "$ROOT" "20260719-tst")"
[[ "$r" == "unclaimed" ]] && ok "classified unclaimed — heartbeat log has no line for this ID" || fail "classified '$r' (expected unclaimed)"
rm -rf "$ROOT"

echo ""
echo "5. running + BOTH task file and dispatch heartbeat line -> in-progress (task file alone is sufficient/decisive)"
ROOT="$(mk_root)"
printf '# Task\nid: 20260719-tst\n' > "$ROOT/.orchestrate/tasks/20260719-tst.md"
echo "[2026-07-19T00:00:00Z] tend-auto — dispatching \"a job\" (20260719-tst) [batch 1]" >> "$ROOT/.orchestrate/logs/heartbeat.log"
r="$(is_unclaimed_running_row "$ROOT" "20260719-tst")"
[[ "$r" == "in-progress" ]] && ok "classified in-progress — both signals present" || fail "classified '$r' (expected in-progress)"
rm -rf "$ROOT"

echo ""
echo "6. lock-bypass double-claim window (documentation regression, not a code fix):"
echo "   two independent classification calls against the SAME unclaimed row (simulating two"
echo "   sessions racing past a bypassed tend lock, both reading before either writes its claim"
echo "   signal) BOTH return unclaimed — this is the accepted, documented narrow race from"
echo "   SKILL.md's 'Residual lock-bypass race (accepted, narrow)' note, not a bug this test"
echo "   suite treats as a failure. Asserting it here pins the documented behavior so a future"
echo "   change to the claim rule doesn't silently \"fix\" (or worsen) it without updating the doc."
ROOT="$(mk_root)"
r1="$(is_unclaimed_running_row "$ROOT" "20260719-tst")"
r2="$(is_unclaimed_running_row "$ROOT" "20260719-tst")"
[[ "$r1" == "unclaimed" && "$r2" == "unclaimed" ]] && ok "both racing reads see unclaimed (documented TOCTOU window reproduced)" || fail "r1='$r1' r2='$r2' (expected both unclaimed)"

# This test file is mirrored into two locations (script-divergence convention:
# ai-toolbox source + ai-console project copy), and only the ai-toolbox source
# tree has a sibling SKILL.md (one dir up from tests/). Check every location
# that COULD hold the canonical or installed copy; pass if any one has it, so
# this assertion works unmodified from either mirror.
SKILL_CANDIDATES=(
  "$(cd "$(dirname "$0")/.." && pwd)/SKILL.md"
  "/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/SKILL.md"
  "$HOME/.claude/skills/task-orchestrate/SKILL.md"
)
SKILL_DOC_FOUND=0
for f in "${SKILL_CANDIDATES[@]}"; do
  if [[ -f "$f" ]] && grep -q "Residual lock-bypass race (accepted, narrow)" "$f"; then
    SKILL_DOC_FOUND=1
    break
  fi
done
[[ "$SKILL_DOC_FOUND" -eq 1 ]] && ok "SKILL.md documents the accepted lock-bypass race (T-4 claim-not-wait section)" || fail "SKILL.md missing the 'Residual lock-bypass race (accepted, narrow)' documentation"
rm -rf "$ROOT"

echo ""
echo "── T-4 claim-not-wait: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
