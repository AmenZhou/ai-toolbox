#!/usr/bin/env bash
# test-task-breakdown.sh — SKILL.md doc-conformance for /task-breakdown (v4.0.0)
#
# v4.0.0 lean redesign: the v3.x "every unit = INV → CHALLENGE → IMPL → VERIFY" model produced
# 28-phase / 85K task files that repeated checks task-orchestrate already runs (per-phase critic,
# Completion independent review, final Test & Verify). A unit now defaults to ONE phase (IMPL);
# INV / CHALLENGE / VERIFY are added only when a unit's unknowns or risk earn them. Steps 1b/1c/7b
# were folded into Step 1 and a coverage check; per-phase boilerplate sections became optional.
#
# This is a prose/template skill, so these are grep-based doc assertions (same pattern as
# task-orchestrate/tests/test-task-orchestrate.sh), plus a size ceiling and a mirror check.
#
# Run from anywhere:
#   bash /Users/haimengzhou/apps/ai-toolbox/skills/task-breakdown/tests/test-task-breakdown.sh
set -uo pipefail

PASS=0
FAIL=0
SKILL_SRC="/Users/haimengzhou/apps/ai-toolbox/skills/task-breakdown/SKILL.md"
CLAUDE_MIRROR="$HOME/.claude/skills/task-breakdown/SKILL.md"
GEMINI_MIRROR="$HOME/.gemini/skills/task-breakdown/SKILL.md"
MAX_LINES=200   # re-bloat guard: v3.2.0 was 879 lines; add a rule only by removing one

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

skill_has() {
  if grep -qE "$1" "$SKILL_SRC" 2>/dev/null; then ok "$2"; else fail "$2"; fi
}

skill_lacks() {
  if grep -qE "$1" "$SKILL_SRC" 2>/dev/null; then fail "$2"; else ok "$2"; fi
}

echo ""
echo "── task-breakdown — test suite (v4.0.0) ─────"

echo ""
echo "1. Source file, version, size ceiling"
if [ -f "$SKILL_SRC" ]; then ok "SKILL.md source exists in ai-toolbox"; else fail "SKILL.md source missing at $SKILL_SRC"; fi
skill_has '^version: 4\.0\.0' "version is 4.0.0 (lean redesign)"
LINES=$(wc -l < "$SKILL_SRC" 2>/dev/null | tr -d ' ')
LINES=${LINES:-0}
if [ "$LINES" -le "$MAX_LINES" ]; then
  ok "SKILL.md is $LINES lines (ceiling $MAX_LINES)"
else
  fail "SKILL.md is $LINES lines, over the $MAX_LINES ceiling — trim before adding"
fi

echo ""
echo "2. Writes a task file, never executes, no inbox model"
skill_has "HARD RULE:\*\* this skill NEVER starts execution" "HARD RULE: never starts execution"
skill_has "stops at the go-gate|STOP at the go-gate" "stops at the go-gate"
skill_lacks 'stage(s|d)? (each ticket|them|it) (in|to) \.orchestrate/inbox/' "no live instruction to stage inbox tickets"
OLD_MECH_COUNT=$(grep -c "blocked_by_ticket\|resolve_depends_on()" "$SKILL_SRC" 2>/dev/null)
if [ "${OLD_MECH_COUNT:-0}" -eq 0 ]; then ok "no blocked_by_ticket/resolve_depends_on references"; else fail "stale blocked_by_ticket references: $OLD_MECH_COUNT"; fi

echo ""
echo "3. Lean phase model"
skill_has "defaults to \*\*one phase\*\*" "a unit defaults to one phase (IMPL)"
skill_has '`<ID>-INV`.*Only when|\| `<ID>-INV`' "INV is conditional (table row)"
skill_has '`<ID>-CHALLENGE`' "CHALLENGE is defined"
skill_has '`<ID>-VERIFY`' "VERIFY is defined"
skill_has "needs_human" "CHALLENGE failure routes into task-orchestrate's needs_human, no bespoke ask-flow"
skill_has "exceeds ~12 phases" "plan size cap (~12 phases) stated"
skill_lacks "Every unit is four phases, always" "old 'four phases always' rule removed"
skill_lacks "every unit gets four chained phases" "old four-chained-phases principle removed"
skill_lacks "## Step 1b|## Step 1c|## Step 7b" "old Steps 1b/1c/7b folded away"

echo ""
echo "4. Phase template"
skill_has '### Phase N: <ID>-<STAGE>' "phase header format documented"
skill_has 'depends_on: <phase number\(s\) or none>' "depends_on uses phase numbers"
for section in '\*\*Description\*\*' '\*\*Design\*\*' '\*\*Test Plan\*\*'; do
  skill_has "$section" "template keeps $section"
done
skill_has 'Do not write "None\." boilerplate' "optional sections carry no 'None.' boilerplate"
skill_has 'existing \+ new == asserted' "count-AC derivation rule kept"

echo ""
echo "5. Dependencies and overlap"
skill_has "\*\*specific phase\*\* that produces the dependency" "cross-unit depends_on names a specific phase"
skill_has "never a \`depends_on:\`|never a .depends_on:." "live overlaps are never a depends_on"

echo ""
echo "6. Gating"
skill_has '`mode: auto` by default' "auto is the default"
skill_has '`mode: gated` only if' "gated only on a real risky op"
skill_has 'kube-cmd-\*\.sh' "gated IMPL writes a review script"
skill_lacks '[ `(]/tmp/kube-cmd' "no stale /tmp review-script path (blocked in this project)"

echo ""
echo "7. Task file schema and registration"
skill_has '^id: \{ID\}$' "schema includes id"
skill_has '^source: task-breakdown$' "schema sets source"
skill_has '^## Out of Scope$' "schema has a job-level Out of Scope section"
skill_has '^## Wiki Context$' "schema has a Wiki Context section"
skill_has '/wiki-context-pack "<job title/goal>" --budget 1500' "single wiki-context-pack invocation documented"
skill_has 'Registration is a plain file edit' "registration is a direct file edit"
skill_has 'final `Test & Verify` phase is mandatory' "final Test & Verify is mandatory"
skill_has 'do not add a second aggregate' "no second aggregate check"

echo ""
echo "8. Go-gate"
skill_has '`/orch resume`, pick \{ID\}, then "go" or "go auto"' "go-gate references /orch resume"
skill_has 'Nothing has been executed' "states nothing has been executed"
skill_has 'type "grill"' "grill option surfaced"
skill_has 'never invoke it unprompted' "grill is never automatic"

echo ""
echo "9. Example is lean"
skill_has 'a three-unit job, 6 phases \(not 13\)' "worked example shows 6 phases, not 13"

echo ""
echo "10. ticket-planning referenced for scope boundary"
skill_has "ticket-planning" "still points single-ticket refinement at ticket-planning"

echo ""
echo "11. sync.sh mirrors"
for mirror in "$CLAUDE_MIRROR" "$GEMINI_MIRROR"; do
  if [ -f "$mirror" ]; then
    if diff -q "$SKILL_SRC" "$mirror" >/dev/null 2>&1; then ok "$mirror is byte-identical to source"; else fail "$mirror differs from source — run sync.sh"; fi
  else
    fail "$mirror not found"
  fi
done

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"

[ "$FAIL" -eq 0 ] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED — see above" && exit 1
