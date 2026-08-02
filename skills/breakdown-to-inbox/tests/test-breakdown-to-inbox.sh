#!/usr/bin/env bash
# test-breakdown-to-inbox.sh — SKILL.md doc-conformance for /breakdown-to-inbox
#
# Covers the SCOPE-1-IMPL change (20260730-inbox-E404): the Step 3 per-ticket
# template gained a 7th section — **Out of Scope / Prohibitions** — placed after
# Acceptance Criteria and before Open Questions; all "6-section" references were
# reconciled to 7; the Design guidance's "what NOT to do" clause was deduped into
# the new section; VERIFY guidance was wired to diff against the Prohibition list;
# and the three worked-example tickets (DS-1-INV/IMPL/VERIFY) each carry the
# section. This is a prose/template skill with no runtime/executable code, so
# these are grep-based doc assertions (same pattern as
# task-orchestrate/tests/test-task-orchestrate.sh's skill_has helper), plus a
# byte-identity check against the sync.sh mirrors.
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
echo "── breakdown-to-inbox — test suite ──────────────"

# ── 1. Source file exists ────────────────────────────────────────────────────
echo ""
echo "1. Source file"

if [ -f "$SKILL_SRC" ]; then
  ok "SKILL.md source exists in ai-toolbox"
else
  fail "SKILL.md source missing at $SKILL_SRC"
fi

# ── 2. Out of Scope / Prohibitions section ───────────────────────────────────
echo ""
echo "2. Out of Scope / Prohibitions section"

skill_has '\*\*Out of Scope / Prohibitions\*\*' "template defines Out of Scope / Prohibitions section header"

# Count occurrences: Step 3 template + Step 2 point 3 + Design + 3 worked examples = 7
# (grep -c exits nonzero when it finds zero matches, so don't `||` an echo after it —
# that would append a second line to real output; redirect stderr only, default to 0 on read failure.)
OCCURRENCES=$(grep -c "Out of Scope / Prohibitions" "$SKILL_SRC" 2>/dev/null)
OCCURRENCES=${OCCURRENCES:-0}
if [ "$OCCURRENCES" -ge 7 ]; then
  ok "Out of Scope / Prohibitions appears >= 7 times (found $OCCURRENCES: template + guidance + worked examples)"
else
  fail "Out of Scope / Prohibitions appears fewer than 7 times (found $OCCURRENCES)"
fi

# Placement: must sit between Acceptance Criteria and Open Questions in the Step 3 template
if awk '/^\*\*Acceptance Criteria\*\*/{ac=NR} /^\*\*Out of Scope \/ Prohibitions\*\*/{oos=NR} /^\*\*Open Questions\*\*/{oq=NR; exit}
        END{exit !(ac && oos && oq && ac<oos && oos<oq)}' "$SKILL_SRC"; then
  ok "Out of Scope / Prohibitions is placed after Acceptance Criteria and before Open Questions"
else
  fail "Out of Scope / Prohibitions is not correctly placed between Acceptance Criteria and Open Questions"
fi

# ── 3. Stale "6-section" references reconciled ───────────────────────────────
echo ""
echo "3. Stale 6-section references reconciled"

skill_lacks '6-section|6 section|all 6' "no stale '6-section' references remain (template is now 7 sections)"
skill_has 'all 7 sections' "Step 3 explicitly states all 7 sections"

# ── 4. Design guidance dedup + VERIFY wiring ─────────────────────────────────
echo ""
echo "4. Design guidance dedup + VERIFY wiring"

skill_has 'what NOT to touch.*belong in \*\*Out of Scope / Prohibitions\*\*' \
  "Design guidance defers 'what NOT to touch' to Out of Scope / Prohibitions (deduped, not restated)"
skill_has 'diff the actual changed files\s*$|against the Out of Scope / Prohibitions list' \
  "VERIFY guidance is wired to diff against the Out of Scope / Prohibitions list"

# ── 5. Worked-example tickets updated ────────────────────────────────────────
echo ""
echo "5. Worked-example tickets (DS-1-INV / DS-1-IMPL / DS-1-VERIFY)"

for ticket in "DS-1-INV" "DS-1-IMPL" "DS-1-VERIFY"; do
  # Find the ticket's heading line, then check the next ~40 lines contain the section
  block=$(awk -v t="$ticket" '
    $0 ~ ("### " t) {found=1}
    found {print; c++}
    found && c>40 {exit}
  ' "$SKILL_SRC")
  if echo "$block" | grep -q '\*\*Out of Scope / Prohibitions\*\*'; then
    ok "$ticket worked example carries Out of Scope / Prohibitions section"
  else
    fail "$ticket worked example is missing Out of Scope / Prohibitions section"
  fi
done

# ── 6. ticket-planning.md untouched (per plan) ───────────────────────────────
echo ""
echo "6. ticket-planning left untouched"

TICKET_PLANNING="/Users/haimengzhou/apps/ai-toolbox/skills/ticket-planning/SKILL.md"
if [ -f "$TICKET_PLANNING" ]; then
  if grep -q "not have.*ticket-planning\|does not invoke ticket-planning" "$SKILL_SRC" 2>/dev/null; then
    ok "breakdown-to-inbox documents its scope divergence from ticket-planning"
  else
    fail "breakdown-to-inbox does not document scope divergence from ticket-planning"
  fi
else
  ok "ticket-planning/SKILL.md not found locally — skipping cross-file check (not this task's scope)"
fi

# ── 8. Step 1b — live control plane scan (DEP-SCAN-IMPL, 20260801-inbox-70BD) ─
echo ""
echo "8. Step 1b live control plane scan"

skill_has '## Step 1b — Scan the live control plane for overlapping work' \
  "Step 1b header exists"
skill_has 'non-terminal registry rows' "Step 1b names project.md non-terminal registry rows as a scan source"
skill_has 'pending.*running.*awaiting_go.*needs_human' \
  "Step 1b enumerates the 4 non-terminal statuses (pending/running/awaiting_go/needs_human)"
skill_has 'Undrained root inbox — `\.orchestrate/inbox/\*\.md`' \
  "Step 1b names undrained root inbox as a scan source"
skill_has 'Undrained gated inbox — `\.orchestrate/inbox/gated/\*\.md`' \
  "Step 1b names undrained gated inbox as a scan source"
skill_has 'Exclude any file carrying a `deferred_at:` header' \
  "Step 1b excludes deferred_at: files from the undrained-inbox scan"
skill_has 'Explicit human-named ticket ID or title.*hard-dependency candidate' \
  "Step 1b heuristic 1 (explicit ID/title) is classified hard"
skill_has 'Target path overlap.*soft conflict only' \
  "Step 1b heuristic 2 (target path) is classified soft"
skill_has 'Shared resource keywords.*soft conflict only' \
  "Step 1b heuristic 3 (shared keywords) is classified soft"

# ── 9. Step 4 — live-overlap hard-dependency wiring ──────────────────────────
echo ""
echo "9. Step 4 live-overlap wiring"

skill_has 'Live-overlap hard dependencies \(from Step 1b\)' \
  "Step 4 documents wiring live-overlap hard-dependency candidates"
skill_has 'This already resolves today' \
  "Step 4 states the live-registry-ID reference form already resolves via drain-inbox.sh Stage 2"
skill_has 'Known,\s*$|Known,.*unclosed race window' \
  "Step 4 documents the undrained-inbox-basename race-window caveat explicitly"
skill_has 'never.*wired into `blocked_by_ticket:`.*here' \
  "Step 4 states soft conflicts from Step 1b are never wired as a hard dependency"

# ── 10. Step 6 — header comment documents all 3 blocked_by_ticket: forms ─────
echo ""
echo "10. Step 6 blocked_by_ticket: header forms"

skill_has 'a live prior-run registry task ID from Step 1b' \
  "Step 6 header comment documents the live-registry-ID reference form"
skill_has 'a pre-existing undrained inbox file.s basename from Step 1b' \
  "Step 6 header comment documents the undrained-inbox-basename reference form"

# ── 11. Step 7 — Live overlaps summary block ─────────────────────────────────
echo ""
echo "11. Step 7 Live overlaps block"

skill_has '⚠ Live overlaps \(not blocked — for awareness only\)' \
  "Step 7 defines the ⚠ Live overlaps summary block"
skill_has 'omit this block entirely when there are none' \
  "Step 7 states the Live overlaps block is only printed when soft conflicts exist"
skill_has 'may now name a \*\*pre-existing\*\* live' \
  "Step 7 notes the depends-on column may reference a pre-existing (not just same-batch) ticket"

# ── 7. sync.sh mirrors are byte-identical ────────────────────────────────────
echo ""
echo "7. sync.sh mirrors"

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
