#!/usr/bin/env bash
# test-breakdown-to-inbox.sh — SKILL.md doc-conformance for /breakdown-to-inbox
#
# Covers the v3.0.0 redesign (task 20260808-211243): breakdown-to-inbox no longer stages
# tickets in .orchestrate/inbox/ for a background tend/drain-inbox.sh cycle to pick up — that
# apparatus was archived in this project on 2026-08-06 (background launchd execution proved
# infeasible for the Claude Code CLI). Instead the skill writes ONE task-orchestrate task file
# (.orchestrate/tasks/{ID}.md) for the whole decomposed job, with every unit expressed as FOUR
# chained phases (was three tickets) — Investigation/Plan, the new Challenge phase (adversarial
# review of the INV plan before Implementation may depend on it), Implementation, Verification —
# and registers the row in project.md via a direct file edit, since this project's
# .orchestrate/bin/ has no update-registry-row.sh/drain-inbox.sh/check-depends-on.sh equivalents.
# This is a prose/template skill with no runtime/executable code, so these are grep-based doc
# assertions (same pattern as task-orchestrate/tests/test-task-orchestrate.sh's skill_has
# helper), plus a byte-identity check against the sync.sh mirrors.
#
# Run from anywhere:
#   bash /Users/haimengzhou/apps/ai-toolbox/skills/breakdown-to-inbox/tests/test-breakdown-to-inbox.sh
set -uo pipefail

PASS=0
FAIL=0
SKILL_SRC="/Users/haimengzhou/apps/ai-toolbox/skills/breakdown-to-inbox/SKILL.md"
CLAUDE_MIRROR="$HOME/.claude/skills/breakdown-to-inbox/SKILL.md"
GEMINI_MIRROR="$HOME/.gemini/skills/breakdown-to-inbox/SKILL.md"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

skill_has() {
  local pattern="$1"
  local label="$2"
  if grep -qE "$pattern" "$SKILL_SRC" 2>/dev/null; then
    ok "$label"
  else
    fail "$label"
  fi
}

skill_lacks() {
  local pattern="$1"
  local label="$2"
  if grep -qE "$pattern" "$SKILL_SRC" 2>/dev/null; then
    fail "$label"
  else
    ok "$label"
  fi
}

echo ""
echo "── breakdown-to-inbox — test suite (v3.0.0) ─────"

# ── 1. Source file exists, version bumped ────────────────────────────────────
echo ""
echo "1. Source file"

if [ -f "$SKILL_SRC" ]; then
  ok "SKILL.md source exists in ai-toolbox"
else
  fail "SKILL.md source missing at $SKILL_SRC"
fi

skill_has '^version: 3\.0\.0' "version bumped to 3.0.0 (major redesign — task-file model)"

# ── 2. No inbox-staging model left as the live instruction ───────────────────
echo ""
echo "2. Inbox-staging model removed"

skill_has "HARD RULE:\*\* This skill NEVER starts execution\. It writes the task file, registers" \
  "HARD RULE describes writing a task file, not staging inbox tickets"
skill_has "No \`\.orchestrate/inbox/\` writes\." \
  "Step 6 states no .orchestrate/inbox/ writes"
skill_lacks 'stage(s|d)? (each ticket|them|it) (in|to) \.orchestrate/inbox/ for (a )?tend' \
  "no live instruction to stage tickets in .orchestrate/inbox/ for tend to drain"

# blocked_by_ticket / resolve_depends_on should not appear as a live mechanism this skill uses —
# only (if at all) inside explanatory "why this changed" prose, which the count-based check below
# tolerates a small number of incidental mentions for.
OLD_MECH_COUNT=$(grep -c "blocked_by_ticket\|resolve_depends_on()" "$SKILL_SRC" 2>/dev/null)
OLD_MECH_COUNT=${OLD_MECH_COUNT:-0}
if [ "$OLD_MECH_COUNT" -eq 0 ]; then
  ok "no blocked_by_ticket:/resolve_depends_on() references remain (old cross-file model fully removed)"
else
  fail "found $OLD_MECH_COUNT stale blocked_by_ticket:/resolve_depends_on() reference(s) — expected 0"
fi

# ── 3. Four-phase-per-unit model (CHALLENGE added) ────────────────────────────
echo ""
echo "3. Four-phase-per-unit model"

skill_has "every unit gets four chained phases: Investigation/Plan" \
  "CORE PRINCIPLE states four chained phases per unit"
skill_has "Investigation/Plan → Challenge →" \
  "phase chain is INV → Challenge → ..."
skill_has "CHALLENGE.*Adversarial review of the INV plan" \
  "Step 2 defines the CHALLENGE phase as an adversarial review of the INV plan"
skill_has "If the gap needs human judgment" \
  "CHALLENGE phase documents the ❌ / needs_human path for unresolvable human-judgment gaps"
skill_has "First-Pass Auto-Resolution Check → Human-Only Block Classifier → \`needs_human\`" \
  "CHALLENGE failure explicitly routes into task-orchestrate's existing needs_human machinery (no bespoke ask-flow)"
skill_has "Every unit is four phases, always" \
  "Constraints section states four phases per unit, always"

CHALLENGE_COUNT=$(grep -c "CHALLENGE" "$SKILL_SRC" 2>/dev/null)
CHALLENGE_COUNT=${CHALLENGE_COUNT:-0}
if [ "$CHALLENGE_COUNT" -ge 8 ]; then
  ok "CHALLENGE appears >= 8 times (found $CHALLENGE_COUNT: Step 2 definition + template + worked example)"
else
  fail "CHALLENGE appears fewer than 8 times (found $CHALLENGE_COUNT) — expected coverage across Step 2/3/6/7 + worked example"
fi

# ── 4. Per-phase template retains prior section content ──────────────────────
echo ""
echo "4. Per-phase template (Step 3)"

for section in '\*\*Description\*\*' '\*\*Out of Scope / Prohibitions\*\*' '\*\*Open Questions\*\*' \
               '\*\*Design\*\*' '\*\*Implementation Plan\*\*' '\*\*Test Plan\*\*'; do
  skill_has "$section" "Step 3 template retains $section section"
done

skill_has '### Phase N: \[ID\]-\[STAGE\]' \
  "Step 3 phase header format documented (### Phase N: [ID]-[STAGE] — [title] [executor · type])"
skill_has 'depends_on: <phase number\(s\)' \
  "Step 3 phase header uses depends_on: with phase numbers, not blocked_by_ticket:"

OOS_COUNT=$(grep -c "Out of Scope / Prohibitions" "$SKILL_SRC" 2>/dev/null)
OOS_COUNT=${OOS_COUNT:-0}
if [ "$OOS_COUNT" -ge 6 ]; then
  ok "Out of Scope / Prohibitions appears >= 6 times (found $OOS_COUNT: template + guidance + 4 worked-example phases)"
else
  fail "Out of Scope / Prohibitions appears fewer than 6 times (found $OOS_COUNT)"
fi

# ── 5. Step 4 — plain phase-number dependencies, live overlaps demoted ───────
echo ""
echo "5. Step 4 dependencies"

skill_has '\*\*specific phase number\*\* that actually produces or needs the dependency' \
  "Step 4 points cross-unit dependencies at a specific phase number"
skill_has 'Live overlaps are never wired as a dependency' \
  "Step 4 states live overlaps are never wired as a real dependency"
skill_has 'no script in this project.s' \
  "Step 4 explains why: no check-depends-on.sh equivalent exists in this project"
skill_has 'prominent warning block' \
  "Step 4 routes live overlaps to a prominent warning instead"

# ── 6. Step 5 — whole-task (not per-ticket) gating ────────────────────────────
echo ""
echo "6. Step 5 gating"

skill_has 'gating is now a \*\*single decision for the whole task file\*\*' \
  "Step 5 states gating is a single whole-task decision"
skill_has 'Set \*\*`mode: gated`\*\* only when at least one' \
  "Step 5 gates the whole task if any unit's Implementation phase is risky"
skill_has "unit's Implementation phase involves:" \
  "Step 5 scopes the gating trigger to a unit's Implementation phase"

# ── 7. Step 6 — direct task-file + direct-Edit registration, no bin/ helper ──
echo ""
echo "7. Step 6 registration"

skill_has 'Registration uses direct file operations, not a helper script' \
  "Step 6 states registration uses direct file operations"
skill_has 'contains no `update-registry-row\.sh` or equivalent' \
  "Step 6 states no update-registry-row.sh equivalent exists"
skill_has '^id: \{ID\}$' "Step 6 schema block includes id: {ID}"
skill_has '^total_phases: <4 × unit count, \+ 1' \
  "Step 6 schema documents total_phases = 4 × units + 1 mandatory final phase"
skill_has '^source: breakdown-to-inbox$' "Step 6 schema sets source: breakdown-to-inbox"
skill_has 'final .Test & Verify. phase is \*\*mandatory\*\*' \
  "Step 6 states the final aggregate Test & Verify phase is mandatory"

# ── 8. Step 7/8 — phase table + /orch resume go-gate phrasing ────────────────
echo ""
echo "8. Step 7/8 go-gate phrasing"

skill_has '⚠ Live overlaps — not machine-gated, review before "go"' \
  "Step 7 defines the live-overlaps warning block"
skill_has '`/orch resume`, pick \{ID\}, then "go" or "go auto"' \
  "Step 8 go-gate message references /orch resume, not drain-and-start"
skill_lacks 'drain and start the run' \
  "no stale 'drain and start the run' phrasing remains"
skill_has 'registered in project\.md — status:\s*$|status:\s*\nawaiting_go\. Nothing has been executed' \
  "Step 8 states the row is registered awaiting_go and nothing has executed"

# ── 9. Worked example rewritten as one 13-phase task file ───────────────────
echo ""
echo "9. Worked example"

for i in 1 2 3 4; do
  skill_has "### Phase $i: DS-1-" "worked example includes Phase $i for DS-1"
done
skill_has 'total_phases: 13' "worked example task file declares total_phases: 13"
skill_has '\*\*Target:\*\* `/Users/haimengzhou/apps/ads-phase2-review`' \
  "worked example DS-1 phases carry a Target line"
skill_has 'Phase 7 \(`P3-9-IMPL`\) is the only gated phase' \
  "worked example explains the single gated phase drives the whole task's mode: gated"

# ── 10. ticket-planning.md untouched (per plan) ──────────────────────────────
echo ""
echo "10. ticket-planning left untouched"

TICKET_PLANNING="/Users/haimengzhou/apps/ai-toolbox/skills/ticket-planning/SKILL.md"
if [ -f "$TICKET_PLANNING" ]; then
  if grep -q "ticket-planning" "$SKILL_SRC" 2>/dev/null; then
    ok "breakdown-to-inbox still references ticket-planning for its scope boundary"
  else
    fail "breakdown-to-inbox no longer references ticket-planning"
  fi
else
  ok "ticket-planning/SKILL.md not found locally — skipping cross-file check (not this task's scope)"
fi

# ── 11. sync.sh mirrors are byte-identical ────────────────────────────────────
echo ""
echo "11. sync.sh mirrors"

if [ -f "$CLAUDE_MIRROR" ]; then
  if diff -q "$SKILL_SRC" "$CLAUDE_MIRROR" >/dev/null 2>&1; then
    ok "~/.claude/skills/breakdown-to-inbox/SKILL.md is byte-identical to source"
  else
    fail "~/.claude/skills/breakdown-to-inbox/SKILL.md differs from source — run sync.sh"
  fi
else
  fail "~/.claude/skills/breakdown-to-inbox/SKILL.md mirror not found"
fi

if [ -f "$GEMINI_MIRROR" ]; then
  if diff -q "$SKILL_SRC" "$GEMINI_MIRROR" >/dev/null 2>&1; then
    ok "~/.gemini/skills/breakdown-to-inbox/SKILL.md is byte-identical to source"
  else
    fail "~/.gemini/skills/breakdown-to-inbox/SKILL.md differs from source — run sync.sh"
  fi
else
  fail "~/.gemini/skills/breakdown-to-inbox/SKILL.md mirror not found"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"

[ "$FAIL" -eq 0 ] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED — see above" && exit 1
