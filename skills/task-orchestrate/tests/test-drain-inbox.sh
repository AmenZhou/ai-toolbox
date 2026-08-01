#!/usr/bin/env bash
# test-drain-inbox.sh — unit tests for drain-inbox.sh + tend-need-action.sh
#
# Gating contract (SKILL.md "Gating is risk-based, not location-based"):
#   A drained inbox file registers as gated/awaiting_go ONLY when it carries an
#   explicit `gate_reason:` line OR its content describes a genuine risky op
#   (Gating Criteria). A bare `mode: gated` marker or placement under gated/ is a
#   HINT, not a hard gate — safe tasks are DE-GATED to auto/pending so the tend
#   job can run them without waiting for a human "go".
#   SQL DML keywords (UPDATE/DELETE/DROP/ALTER/...) gate only when UPPERCASE
#   (real SQL); lowercase English prose "update the docs" must NOT gate.
set -euo pipefail

PASS=0
FAIL=0
TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# ── Expected-fail (xfail) reporting ───────────────────────────────────────────
# Regression tests that EXPOSE a known, still-open defect must lock in the
# desired behavior WITHOUT turning the suite red (other tend cycles gate on this
# script's exit code). xok() = the known-defect is still present as documented
# (logged, not counted as a hard failure). xunexpected() = the defect appears to
# be FIXED — a loud reminder to promote the assertion to a hard ok()/fail().
# Tracked separately from PASS/FAIL so run-tests.sh stays green.
XFAIL=0
XFIXED=0
xok()         { echo "  ⚠ xfail (known, not yet fixed): $1"; XFAIL=$((XFAIL+1)); }
xunexpected() { echo "  ★ xfail NOW PASSES — promote to a hard assertion: $1"; XFIXED=$((XFIXED+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
[[ -d "$PROJECT_ROOT/.orchestrate/bin" ]] || { echo "FATAL: $PROJECT_ROOT/.orchestrate/bin not found — PROJECT_ROOT path computation is broken (expected .../ai-console/.orchestrate/bin)" >&2; exit 1; }
DRAIN="$PROJECT_ROOT/.orchestrate/bin/drain-inbox.sh"
DEDUP="$PROJECT_ROOT/.orchestrate/bin/followup-dedup.sh"
NEED="$PROJECT_ROOT/.orchestrate/bin/tend-need-action.sh"

# row_field <project.md> <id> <awk-field>  → trimmed value of a registry row field
row_field() {
  awk -F'|' -v id="$2" -v f="$3" '
    $0 ~ ("\\| " id " \\|") { v=$f; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit }
  ' "$1"
}

echo ""
echo "── drain-inbox + tend-need-action tests ────────"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drain-test.XXXXXX")"
mkdir -p "$TMP/.orchestrate/inbox/gated" "$TMP/.orchestrate/inbox/processed" "$TMP/.orchestrate/logs"
mkdir -p "$TMP/.orchestrate/bin"
cp "$DRAIN" "$DEDUP" "$NEED" "$TMP/.orchestrate/bin/"
chmod +x "$TMP/.orchestrate/bin/"*.sh

# Stub osascript so drain-inbox.sh notify_gated_once (AT-1) does NOT fire real
# desktop notifications during the test run. Prepend to PATH for the whole script.
mkdir -p "$TMP/stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/stub/osascript"
chmod +x "$TMP/stub/osascript"
export PATH="$TMP/stub:$PATH"

cat > "$TMP/.orchestrate/project.md" << 'EOF'
# Orchestrate — drain-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| done-1 | finished | auto | 1 | complete | 2026-01-01T00:00:00Z |
EOF

echo ""
echo "1. tend-need-action idle (no inbox, no actionable registry)"
OUT="$(bash "$TMP/.orchestrate/bin/tend-need-action.sh" "$TMP")"
if echo "$OUT" | grep -q 'NEED_ACTION=0' && echo "$OUT" | grep -q 'REGISTRY_ACTIONABLE=0'; then
  ok "idle project reports NEED_ACTION=0"
else
  fail "expected idle — got: $OUT"
fi

# ── Seed inbox fixtures covering every gating path ────────────────────────────
# (a) SAFE bare `mode: gated` under gated/ — the GINBOX-1/2/3 case → must DE-GATE.
cat > "$TMP/.orchestrate/inbox/gated/safe-enhance.md" << 'EOF'
mode: gated
source: self

# [ENHANCE] improve a log scanner

## Goal
Update the wording in a doc and delete a stale reference. Pure file edit, no risky op.

## Acceptance Criteria
- edited
EOF
# (b) Explicit human override → must GATE.
cat > "$TMP/.orchestrate/inbox/override.md" << 'EOF'
gate_reason: human wants eyes on this change

# Sensitive config tweak

## Goal
Adjust a config value.

## Acceptance Criteria
- changed
EOF
# (c) Genuine risky shell op → must GATE.
cat > "$TMP/.orchestrate/inbox/risky-rm.md" << 'EOF'
# Cache cleanup

## Goal
rm -rf the stale cache directory.

## Acceptance Criteria
- removed
EOF
# (d) Real SQL DML (UPPERCASE) → must GATE.
cat > "$TMP/.orchestrate/inbox/sql.md" << 'EOF'
# DB migration

## Goal
Run UPDATE accounts SET tier=1 then DELETE FROM stale_rows.

## Acceptance Criteria
- migrated
EOF
# (e) IMP-1: risky verb appears ONLY inside a prohibition (negated) → must DE-GATE.
# Every RISKY_OP_RE_CI hit here sits on a line that also carries a negation marker.
cat > "$TMP/.orchestrate/inbox/negated-only.md" << 'EOF'
# Tidy a docs page

## Goal
Reword a markdown section. This is a pure file edit.

## Constraints
- Never rm -rf anything; do NOT git push --force; complete without sending email.

## Acceptance Criteria
- edited
EOF
# (f) SECURITY: a single physical line carries BOTH a negation clause AND a
# genuine imperative risky op in another clause. Correct = GATE (the imperative
# rm -rf / git push --force is real). Current code de-gates because the whole
# line matches NEGATION_RE — the [SECURITY] mixed-clause false-negative. Two
# files so each risky verb is isolated for a clean gated/auto assertion.
cat > "$TMP/.orchestrate/inbox/mixed-clause-rm.md" << 'EOF'
# Reset the dist tree

## Goal
This is not optional. Run rm -rf /tmp/foo/dist to clear the build output.

## Acceptance Criteria
- cleared
EOF
cat > "$TMP/.orchestrate/inbox/mixed-clause-push.md" << 'EOF'
# Land the hotfix

## Goal
Do not stop, but git push --force the hotfix branch once tests are green.

## Acceptance Criteria
- pushed
EOF
# (g) BUG: contraction negations. A purely-negated risky op expressed with a
# contraction (don't / won't / isn't / can't / cannot) should DE-GATE (auto),
# but NEGATION_RE (which only word-bounds "n.t" with a non-letter before "n")
# misses don't/won't/isn't/can't, and has no token for the apostrophe-less
# "cannot". One file per contraction so each de-gate is asserted independently.
cat > "$TMP/.orchestrate/inbox/contraction-dont.md" << 'EOF'
# Contraction dont reword

## Goal
Reword a section. Don't run rm -rf anything — this is a pure file edit.

## Acceptance Criteria
- edited
EOF
cat > "$TMP/.orchestrate/inbox/contraction-wont.md" << 'EOF'
# Contraction wont reword

## Goal
Reword a section. We won't git push --force here; leave the branch alone.

## Acceptance Criteria
- edited
EOF
cat > "$TMP/.orchestrate/inbox/contraction-cannot.md" << 'EOF'
# Contraction cannot reword

## Goal
Reword a section. We cannot rm -rf the prod dir; this is docs-only.

## Acceptance Criteria
- edited
EOF

echo ""
echo "2. drain DE-GATES a safe bare \`mode: gated\` file under gated/ (GINBOX regression)"
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
if [[ -f "$TMP/.orchestrate/inbox/processed/safe-enhance.md" ]]; then
  ok "safe file moved to processed/"
else
  fail "safe file not moved to processed/"
fi
SID="$(awk -F'|' '/log scanner/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
if [[ "$(row_field "$TMP/.orchestrate/project.md" "$SID" 4)" == "auto" \
   && "$(row_field "$TMP/.orchestrate/project.md" "$SID" 6)" == "pending" ]]; then
  ok "safe gated/ file registered as auto/pending (de-gated)"
else
  fail "safe gated/ file was NOT de-gated: $(grep 'log scanner' "$TMP/.orchestrate/project.md")"
fi
if grep -q 'de-gated' "$TMP/.orchestrate/logs/heartbeat.log"; then
  ok "de-gate logged to heartbeat"
else
  fail "de-gate not logged"
fi

echo ""
echo "3. drain GATES a file with an explicit gate_reason:"
OID="$(awk -F'|' '/Sensitive config tweak/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
if [[ "$(row_field "$TMP/.orchestrate/project.md" "$OID" 4)" == "gated" \
   && "$(row_field "$TMP/.orchestrate/project.md" "$OID" 6)" == "awaiting_go" ]]; then
  ok "gate_reason file registered as gated/awaiting_go"
else
  fail "gate_reason file not gated: $(grep 'Sensitive config tweak' "$TMP/.orchestrate/project.md")"
fi

echo ""
echo "4. drain GATES genuine risky ops (rm -rf and UPPERCASE SQL DML)"
RID="$(awk -F'|' '/Cache cleanup/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
QID="$(awk -F'|' '/DB migration/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
if [[ "$(row_field "$TMP/.orchestrate/project.md" "$RID" 6)" == "awaiting_go" ]]; then
  ok "rm -rf task gated"
else
  fail "rm -rf task not gated"
fi
if [[ "$(row_field "$TMP/.orchestrate/project.md" "$QID" 6)" == "awaiting_go" ]]; then
  ok "UPPERCASE SQL DML task gated"
else
  fail "SQL DML task not gated"
fi

echo ""
echo "5. false-positive guard: English 'update/delete' prose does NOT gate"
# safe-enhance.md goal literally says 'Update the wording ... delete a stale reference'.
# Those lowercase English words must NOT trigger the SQL-DML gate (it already
# verified auto/pending in test 2 — assert the heartbeat shows a plain registration).
if grep -qE 'registered "?\[?ENHANCE' "$TMP/.orchestrate/logs/heartbeat.log" \
   || row_field "$TMP/.orchestrate/project.md" "$SID" 6 | grep -q pending; then
  ok "lowercase update/delete prose stayed auto (no false-positive gate)"
else
  fail "English update/delete prose wrongly gated"
fi

echo ""
echo "6. IMP-1: a ticket whose ONLY risky-op hits are negated does NOT gate"
# negated-only.md mentions 'rm -rf', 'git push --force', 'sending email' — each on
# a line that ALSO carries never/not/without. Imperative intent is benign → auto.
NID="$(awk -F'|' '/Tidy a docs page/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
if [[ "$(row_field "$TMP/.orchestrate/project.md" "$NID" 4)" == "auto" \
   && "$(row_field "$TMP/.orchestrate/project.md" "$NID" 6)" == "pending" ]]; then
  ok "negated-only risky op stayed auto/pending (no false-positive gate)"
else
  fail "negated-only risky op wrongly gated: $(grep 'Tidy a docs page' "$TMP/.orchestrate/project.md")"
fi
# And the imperative + gate_reason cases (tests 3/4) still gate — re-assert here so
# this regression block documents the full negated→auto / imperative→gated /
# gate_reason→gated contract in one place.
if [[ "$(row_field "$TMP/.orchestrate/project.md" "$RID" 6)" == "awaiting_go" ]]; then
  ok "imperative 'rm -rf' still gated alongside negated de-gate"
else
  fail "imperative risky op stopped gating"
fi
if [[ "$(row_field "$TMP/.orchestrate/project.md" "$OID" 6)" == "awaiting_go" ]]; then
  ok "gate_reason: still forces a gate regardless of negation"
else
  fail "gate_reason override stopped gating"
fi

echo ""
echo "7. clause-aware negation regressions (from review 20260629-194C)"
# These lock in the two defects the IMP-1 review found (now FIXED in
# fix-drain-inbox-clause-aware-negation / 20260630-inbox-CAC7). They run through
# the SAME drain-inbox.sh path as every other case (fixtures drained in test 2)
# and assert on the resulting registry row as HARD ok()/fail() assertions.

# row_status <summary-substring> → status field (col 6) of the matching row
row_status() {
  local id
  id="$(awk -F'|' -v s="$1" '$0 ~ s {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
  [[ -n "$id" ]] && row_field "$TMP/.orchestrate/project.md" "$id" 6
}

echo ""
echo "  7a. [SECURITY] mixed-clause: imperative risky op on a line that also"
echo "      contains an unrelated negation MUST gate (clause-aware fix)."
for spec in "Reset the dist tree|rm -rf imperative beside 'not optional'" \
            "Land the hotfix|git push --force imperative beside 'do not stop'"; do
  sub="${spec%%|*}"; desc="${spec#*|}"
  st="$(row_status "$sub")"
  if [[ "$st" == "awaiting_go" ]]; then
    ok "mixed-clause GATED as required ($desc)"
  else
    fail "mixed-clause de-gated to '$st', should be awaiting_go ($desc)"
  fi
done

echo ""
echo "  7b. [BUG] contraction negations: purely-negated risky op via a"
echo "      contraction MUST de-gate to auto (NEGATION_RE now matches them)."
# don't / won't / cannot. (The "do NOT" spelling is already covered by
# negated-only.md in test 6 and de-gates correctly — the contraction and
# apostrophe-less spellings used to regress and are now fixed.)
for spec in "Contraction dont reword|don't run rm -rf" \
            "Contraction wont reword|won't git push --force" \
            "Contraction cannot reword|cannot rm -rf"; do
  sub="${spec%%|*}"; desc="${spec#*|}"
  st="$(row_status "$sub")"
  if [[ "$st" == "pending" ]]; then
    ok "contraction de-gated to auto/pending as required ($desc)"
  else
    fail "contraction gated to '$st', should be pending/auto ($desc)"
  fi
done

echo ""
echo "8. ORPH-1: drain materializes a minimal .orchestrate/tasks/<id>.md at"
echo "   registration time (canonical ## Goal / ## Acceptance Criteria format)"
cat > "$TMP/.orchestrate/inbox/materialize-canonical.md" << 'EOF'
# Materialize canonical ticket

## Goal
Prove the canonical-format ticket's Goal section is carried into the task file.

## Acceptance Criteria
- first criterion
- second criterion
EOF
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
CID="$(awk -F'|' '/Materialize canonical ticket/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
CTF="$TMP/.orchestrate/tasks/${CID}.md"
if [[ -n "$CID" && -f "$CTF" ]]; then
  ok "task file materialized at registration for canonical-format ticket"
else
  fail "no task file materialized for canonical-format ticket (id=$CID)"
fi
if grep -q '^total_phases: 1' "$CTF" 2>/dev/null && grep -q '^### Phase 1' "$CTF" 2>/dev/null \
   && grep -qE '^status: pending' "$CTF" 2>/dev/null; then
  ok "materialized task file has total_phases: 1 + one pending Phase 1 block"
else
  fail "materialized task file missing expected total_phases/Phase 1/status shape"
fi
if grep -q 'Goal section is carried into the task file' "$CTF" 2>/dev/null; then
  ok "Goal content carried into materialized task file"
else
  fail "Goal content NOT carried into materialized task file"
fi
if grep -q 'first criterion' "$CTF" 2>/dev/null && grep -q 'second criterion' "$CTF" 2>/dev/null; then
  ok "Acceptance Criteria bullets carried into materialized task file"
else
  fail "Acceptance Criteria bullets NOT carried into materialized task file"
fi

echo ""
echo "9. ORPH-1: bold-style ticket convention (**Description**/**Acceptance"
echo "   Criteria**, used by self-generated INV/IMPL/VERIFY tickets) also works"
cat > "$TMP/.orchestrate/inbox/materialize-bold.md" << 'EOF'
# Materialize bold-style ticket

**Target:** local machine
**Blocks:** none · **Blocked by:** none

**Description**
Prove the bold-style ticket's Description section is carried into the task file as the Goal.

**Acceptance Criteria**
- [ ] bold-style criterion one
- [ ] bold-style criterion two
EOF
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
BID="$(awk -F'|' '/Materialize bold-style ticket/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
BTF="$TMP/.orchestrate/tasks/${BID}.md"
if [[ -n "$BID" && -f "$BTF" ]] && grep -q 'Description section is carried' "$BTF" 2>/dev/null; then
  ok "bold-style Description carried into materialized task file as Goal"
else
  fail "bold-style Description NOT carried into materialized task file"
fi
if grep -q 'bold-style criterion one' "$BTF" 2>/dev/null && grep -q 'bold-style criterion two' "$BTF" 2>/dev/null; then
  ok "bold-style Acceptance Criteria bullets carried into materialized task file"
else
  fail "bold-style Acceptance Criteria bullets NOT carried into materialized task file"
fi

echo ""
echo "10. ORPH-1: idempotent — re-draining an already-registered ID does not"
echo "    clobber a task file with real progress on it"
printf '\nreal progress marker — must survive\n' >> "$CTF"
CTF_BEFORE="$(cat "$CTF")"
# Re-run drain against the same root; materialize_task_file must no-op since
# the file already exists (the source ticket is already in processed/, so
# there is nothing left in inbox/ to re-drain — this asserts the guard itself
# by calling drain-inbox.sh again and confirming the file is byte-identical).
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
CTF_AFTER="$(cat "$CTF")"
if [[ "$CTF_BEFORE" == "$CTF_AFTER" ]]; then
  ok "re-drain did not clobber an existing task file (idempotent)"
else
  fail "re-drain clobbered an existing task file's content"
fi

echo ""
echo "11. ORPH-1: materialize_task_file() preserves followup_for:/kind: headers"
echo "    verbatim (regression — a dropped header lets a followup ticket spawn"
echo "    a followup-of-itself, since downstream anti-recursion checks grep the"
echo "    constructed task file, not the source inbox ticket; see 20260726-inbox-EED4)"
cat > "$TMP/.orchestrate/inbox/materialize-followup-headers.md" << 'EOF'
followup_for: 99999999-inbox-PARENT
kind: wiki-sync
mode: auto
source: self
triggered_by: 99999999-inbox-PARENT

# Wiki sync for Materialize followup headers test

## Goal
Prove followup_for:/kind: headers survive into the materialized task file.

## Acceptance Criteria
- header survives
EOF
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
HID="$(awk -F'|' '/Wiki sync for Materialize followup headers test/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
HTF="$TMP/.orchestrate/tasks/${HID}.md"
if [[ -n "$HID" && -f "$HTF" ]] && grep -qE '^followup_for: 99999999-inbox-PARENT' "$HTF" 2>/dev/null; then
  ok "followup_for: header preserved verbatim in materialized task file"
else
  fail "followup_for: header NOT preserved in materialized task file (id=$HID)"
fi
if grep -qE '^kind: wiki-sync' "$HTF" 2>/dev/null; then
  ok "kind: header preserved verbatim in materialized task file"
else
  fail "kind: header NOT preserved in materialized task file (id=$HID)"
fi

echo ""
echo "12. CROSS-1: blocked_by_ticket: header resolves to a real depends_on: ID"
echo "    when the referenced ticket was already drained earlier in this SAME"
echo "    batch (structural marker, not just 'Blocked by' prose in ## Goal)"
cat > "$TMP/.orchestrate/inbox/blocker-ticket-b.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session

# Blocker Ticket B

## Goal
This is the ticket another ticket in this same batch is blocked by. Nothing references it.

## Acceptance Criteria
- exists
EOF
cat > "$TMP/.orchestrate/inbox/chained-ticket-a-blocked-by-b.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session
blocked_by_ticket: blocker-ticket-b

# Chained Ticket A

## Goal
Blocked by Ticket B because both edit the shared restrict-paths.sh.

## Acceptance Criteria
- chained
EOF
cat > "$TMP/.orchestrate/inbox/unresolvable-blocked-ticket.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session
blocked_by_ticket: nonexistent-ref-not-in-this-batch

# Unresolvable Blocked Ticket

## Goal
Blocked by a ticket ID that this batch does not know about (not part of this drain run).

## Acceptance Criteria
- registered
EOF
# Filenames are chosen so bash's alphabetical glob expansion drains
# blocker-ticket-b.md BEFORE chained-ticket-a-blocked-by-b.md — the ordering
# this whole mechanism depends on (a ref can only resolve to a ticket already
# registered earlier in the same batch).
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
BLID="$(awk -F'|' '/Blocker Ticket B/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
CHID="$(awk -F'|' '/Chained Ticket A/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
UNID="$(awk -F'|' '/Unresolvable Blocked Ticket/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
BLTF="$TMP/.orchestrate/tasks/${BLID}.md"
CHTF="$TMP/.orchestrate/tasks/${CHID}.md"
UNTF="$TMP/.orchestrate/tasks/${UNID}.md"

if [[ -n "$BLID" && -n "$CHID" ]] && grep -qE "^depends_on: ${BLID}\$" "$CHTF" 2>/dev/null; then
  ok "chained ticket A's depends_on: resolved to blocker ticket B's real ID ($BLID)"
else
  fail "chained ticket A's depends_on: did NOT resolve to B's ID (BLID=$BLID CHID=$CHID, got: $(grep '^depends_on:' "$CHTF" 2>/dev/null))"
fi
if grep -qE '^depends_on: none$' "$BLTF" 2>/dev/null; then
  ok "blocker ticket B itself still has depends_on: none (it carries no blocked_by_ticket: header)"
else
  fail "blocker ticket B unexpectedly has a non-none depends_on:"
fi
if grep -qE '^blocked_by_ticket: blocker-ticket-b$' "$CHTF" 2>/dev/null; then
  ok "blocked_by_ticket: header preserved verbatim in A's materialized task file"
else
  fail "blocked_by_ticket: header NOT preserved in A's materialized task file"
fi
if [[ -n "$UNID" ]] && grep -qE '^depends_on: none$' "$UNTF" 2>/dev/null; then
  ok "unresolvable blocked_by_ticket ref (not registered this batch) leaves depends_on: none"
else
  fail "unresolvable ref wrongly invented a depends_on: ID: $(grep '^depends_on:' "$UNTF" 2>/dev/null)"
fi
if grep -q 'Blocked by a ticket ID that this batch does not know about' "$UNTF" 2>/dev/null; then
  ok "prose describing the (unresolved) block relationship is still preserved in ## Goal"
else
  fail "prose describing the block relationship was lost"
fi

echo ""
echo "13. CROSS-1b: transitive 3-ticket chain (A blocks B blocks C) — B is"
echo "    simultaneously a RESOLVED blocker for C and a ticket blocked by A;"
echo "    each hop must resolve independently within the same batch."
cat > "$TMP/.orchestrate/inbox/chain3-a-root.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session

# Chain3 Root A

## Goal
Root of a 3-ticket chain; nothing blocks this one.

## Acceptance Criteria
- exists
EOF
cat > "$TMP/.orchestrate/inbox/chain3-b-middle.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session
blocked_by_ticket: chain3-a-root

# Chain3 Middle B

## Goal
Blocked by Chain3 Root A; also blocks Chain3 Leaf C.

## Acceptance Criteria
- chained
EOF
cat > "$TMP/.orchestrate/inbox/chain3-c-leaf.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session
blocked_by_ticket: chain3-b-middle

# Chain3 Leaf C

## Goal
Blocked by Chain3 Middle B, which is itself blocked by Chain3 Root A.

## Acceptance Criteria
- chained
EOF
# Filenames sort a < b < c so root drains before middle before leaf — each
# ref can only resolve to a ticket already registered earlier in this batch.
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
AID="$(awk -F'|' '/Chain3 Root A/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
BID="$(awk -F'|' '/Chain3 Middle B/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
CID="$(awk -F'|' '/Chain3 Leaf C/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
ATF="$TMP/.orchestrate/tasks/${AID}.md"
BTF="$TMP/.orchestrate/tasks/${BID}.md"
CTF="$TMP/.orchestrate/tasks/${CID}.md"

if grep -qE '^depends_on: none$' "$ATF" 2>/dev/null; then
  ok "chain3 root A has depends_on: none (no blocked_by_ticket header)"
else
  fail "chain3 root A unexpectedly has a non-none depends_on:"
fi
if [[ -n "$AID" && -n "$BID" ]] && grep -qE "^depends_on: ${AID}\$" "$BTF" 2>/dev/null; then
  ok "chain3 middle B's depends_on: resolved to root A's real ID ($AID)"
else
  fail "chain3 middle B did NOT resolve depends_on: to A's ID (got: $(grep '^depends_on:' "$BTF" 2>/dev/null))"
fi
if [[ -n "$BID" && -n "$CID" ]] && grep -qE "^depends_on: ${BID}\$" "$CTF" 2>/dev/null; then
  ok "chain3 leaf C's depends_on: resolved to middle B's real ID ($BID) — transitive hop"
else
  fail "chain3 leaf C did NOT resolve depends_on: to B's ID (got: $(grep '^depends_on:' "$CTF" 2>/dev/null))"
fi

echo ""
echo "14. materialize_task_file() preserves a wrapped continuation line of a"
echo "    multi-line AC bullet (no leading -/* on the continuation line) instead"
echo "    of truncating it at the line break (20260726-inbox-218B)"
cat > "$TMP/.orchestrate/inbox/wrapped-ac-bullet.md" << 'EOF'
# Wrapped AC bullet ticket

## Goal
Prove a soft-wrapped Acceptance Criteria bullet survives materialization in full.

## Acceptance Criteria
- first criterion wraps across a line break onto a second physical line that has
  no leading dash and must not be truncated at the break
- second criterion is a normal single-line bullet
EOF
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
WID="$(awk -F'|' '/Wrapped AC bullet ticket/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
WTF="$TMP/.orchestrate/tasks/${WID}.md"
if [[ -n "$WID" && -f "$WTF" ]] && grep -q 'no leading dash and must not be truncated at the break' "$WTF" 2>/dev/null; then
  ok "wrapped AC bullet continuation preserved in full, not truncated at line break"
else
  fail "wrapped AC bullet continuation was truncated or dropped (id=$WID)"
fi
if [[ -n "$WID" && -f "$WTF" ]] && grep -q 'first criterion wraps across a line break onto a second physical line that has no leading dash and must not be truncated at the break' "$WTF" 2>/dev/null; then
  ok "wrapped AC bullet merged onto a single logical line (not split into two)"
else
  fail "wrapped AC bullet not merged into a single logical line (got: $(grep -A1 'first criterion' "$WTF" 2>/dev/null))"
fi
if grep -q 'second criterion is a normal single-line bullet' "$WTF" 2>/dev/null; then
  ok "subsequent unwrapped bullet still carried through correctly"
else
  fail "subsequent unwrapped bullet NOT carried through"
fi

echo ""
echo "15. materialize_task_file() folds a THREE-physical-line wrapped AC bullet"
echo "    (two continuation lines, each with different leading whitespace) into"
echo "    a single logical line, and does not bleed into the next bullet"
cat > "$TMP/.orchestrate/inbox/triple-wrap-ac-bullet.md" << 'EOF'
# Triple-wrap AC bullet ticket

## Goal
Prove a THREE-physical-line-wrapped Acceptance Criteria bullet survives materialization in full.

## Acceptance Criteria
- alpha criterion wraps across three physical lines where the first continuation
    has four leading spaces of indentation and the second continuation
  has only two, all of which must fold onto one line
- beta criterion is a normal single-line bullet
EOF
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
TWID="$(awk -F'|' '/Triple-wrap AC bullet ticket/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
TWTF="$TMP/.orchestrate/tasks/${TWID}.md"
if [[ -n "$TWID" && -f "$TWTF" ]] && grep -q 'alpha criterion wraps across three physical lines where the first continuation has four leading spaces of indentation and the second continuation has only two, all of which must fold onto one line' "$TWTF" 2>/dev/null; then
  ok "three-physical-line wrapped AC bullet merged onto a single logical line, all indentation stripped"
else
  fail "three-physical-line wrapped AC bullet not fully merged (got: $(grep -A2 'alpha criterion' "$TWTF" 2>/dev/null))"
fi
if grep -q 'beta criterion is a normal single-line bullet' "$TWTF" 2>/dev/null; then
  ok "bullet following the triple-wrapped bullet still carried through correctly, uncontaminated"
else
  fail "bullet following the triple-wrapped bullet NOT carried through"
fi

echo ""
echo "16. CROSS-2 (20260727-inbox-7D4A): **Blocked by:** markdown-bold prose (not"
echo "    just the blocked_by_ticket: header) resolves to a real depends_on: ID —"
echo "    the exact gap that let 20260727-inbox-1F27 (CH-TABLE-SEED-VERIFY) get"
echo "    depends_on: none despite its body saying '**Blocked by:** CH-TABLE-SEED-IMPL.'"
cat > "$TMP/.orchestrate/inbox/cross2-blocker-b.md" << 'EOF'
mode: gated
source: self
triggered_by: test-session
gate_reason: simulated risky op — this blocker must stay gated/awaiting_go for the test

# CROSS2-BLOCKER-B — Some prerequisite work

## Goal
This is the ticket the prose-referencing ticket below is blocked by.

## Acceptance Criteria
- exists
EOF
cat > "$TMP/.orchestrate/inbox/cross2-dependent-a.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session

# CROSS2-DEPENDENT-A — Depends on B via bold prose, not a header

**Blocks:** none  ·  **Blocked by:** CROSS2-BLOCKER-B.

## Goal
Blocked by CROSS2-BLOCKER-B via plain markdown-bold prose (no blocked_by_ticket: header).

## Acceptance Criteria
- chained
EOF
# Filenames sort b < a's slug ("cross2-blocker-b" < "cross2-dependent-a") so the
# blocker drains first, same-batch, and is already in project.md's registry by
# the time the dependent ticket is resolved.
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
C2BID="$(awk -F'|' '/CROSS2-BLOCKER-B/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
C2AID="$(awk -F'|' '/CROSS2-DEPENDENT-A/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
C2ATF="$TMP/.orchestrate/tasks/${C2AID}.md"
if [[ -n "$C2BID" && -n "$C2AID" ]] && grep -qE "^depends_on: ${C2BID}\$" "$C2ATF" 2>/dev/null; then
  ok "**Blocked by:** prose resolved to blocker B's real ID ($C2BID) — no blocked_by_ticket: header needed"
else
  fail "**Blocked by:** prose did NOT resolve to B's ID (got: $(grep '^depends_on:' "$C2ATF" 2>/dev/null))"
fi
if awk -F'|' -v id="$C2BID" '$0 ~ ("\\| " id " \\|") { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$4); if ($4=="gated") exit 0; exit 1 }' "$TMP/.orchestrate/project.md"; then
  ok "blocker B correctly registered gated (sanity check for the run-job.sh dispatch-gate regression test)"
else
  fail "blocker B unexpectedly not registered gated — sanity check failed"
fi

echo ""
echo "17. CROSS-2: **Blocked by:** prose ALSO resolves against an already-"
echo "    registered sibling from a PRIOR drain-inbox.sh run (not just same-batch)"
cat > "$TMP/.orchestrate/inbox/cross2-prior-blocker-c.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session

# CROSS2-PRIOR-BLOCKER-C — Registered in an earlier drain run

## Goal
Registered alone, in its own drain-inbox.sh invocation, before any dependent references it.

## Acceptance Criteria
- exists
EOF
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
C2CID="$(awk -F'|' '/CROSS2-PRIOR-BLOCKER-C/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
cat > "$TMP/.orchestrate/inbox/cross2-later-dependent-d.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session

# CROSS2-LATER-DEPENDENT-D — Depends on C from a later, separate drain run

**Blocked by:** CROSS2-PRIOR-BLOCKER-C

## Goal
References CROSS2-PRIOR-BLOCKER-C, which was already registered in a prior drain-inbox.sh run —
there is no same-batch BLOCKED_BY_MAP entry for it; resolution must fall back to the registry.

## Acceptance Criteria
- chained
EOF
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
C2DID="$(awk -F'|' '/CROSS2-LATER-DEPENDENT-D/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
C2DTF="$TMP/.orchestrate/tasks/${C2DID}.md"
if [[ -n "$C2CID" && -n "$C2DID" ]] && grep -qE "^depends_on: ${C2CID}\$" "$C2DTF" 2>/dev/null; then
  ok "**Blocked by:** prose resolved to a sibling registered in an EARLIER, separate drain-inbox.sh run"
else
  fail "**Blocked by:** prose did NOT resolve against a prior-run sibling (got: $(grep '^depends_on:' "$C2DTF" 2>/dev/null))"
fi

echo ""
echo "18. CROSS-2: **Blocked by:** none / unresolvable ref never invents an ID"
cat > "$TMP/.orchestrate/inbox/cross2-unresolvable-e.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session

# CROSS2-UNRESOLVABLE-E — References a title that was never registered

**Blocked by:** SOME-TICKET-THAT-DOES-NOT-EXIST

## Goal
Prose names a ticket title that has never been drained/registered in this project.

## Acceptance Criteria
- registered
EOF
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
C2EID="$(awk -F'|' '/CROSS2-UNRESOLVABLE-E/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
C2ETF="$TMP/.orchestrate/tasks/${C2EID}.md"
if [[ -n "$C2EID" ]] && grep -qE '^depends_on: none$' "$C2ETF" 2>/dev/null; then
  ok "unresolvable **Blocked by:** prose ref leaves depends_on: none (never invents an ID)"
else
  fail "unresolvable **Blocked by:** prose ref wrongly invented a depends_on: ID: $(grep '^depends_on:' "$C2ETF" 2>/dev/null)"
fi

echo ""
echo "19. CROSS-1 two-pass fix (20260801-inbox-953C): an INV/IMPL/VERIFY triple"
echo "    dropped into the inbox TOGETHER, with filenames chosen so plain"
echo "    alphabetical glob order drains 953c-impl-*.md BEFORE 953c-inv-*.md —"
echo "    all three depends_on links must still resolve correctly in ONE run."
cat > "$TMP/.orchestrate/inbox/953c-inv-plan-the-thing.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session

# 953C-INV — Plan the thing

## Goal
Investigate and plan. Nothing blocks this one.

## Acceptance Criteria
- plan written
EOF
cat > "$TMP/.orchestrate/inbox/953c-impl-do-the-thing.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session
blocked_by_ticket: 953c-inv-plan-the-thing

# 953C-IMPL — Do the thing

## Goal
Implement per the INV plan. Blocked by the INV ticket above — but that file's
basename ("953c-inv-...") sorts AFTER this file's basename ("953c-impl-...")
in plain alphabetical order, since 'm' < 'n' at the first differing character.
Before the two-pass fix, this reference would fail to resolve because the INV
file's record_batch_id call had not run yet when this file was drained.

## Acceptance Criteria
- implemented
EOF
cat > "$TMP/.orchestrate/inbox/953c-verify-confirm-the-thing.md" << 'EOF'
mode: auto
source: self
triggered_by: test-session
blocked_by_ticket: 953c-impl-do-the-thing

# 953C-VERIFY — Confirm the thing

## Goal
Independently verify. Blocked by the IMPL ticket.

## Acceptance Criteria
- verified
EOF
# Sanity check the actual glob order this test depends on, so a shell with
# different LC_COLLATE/glob behavior fails loudly here instead of silently
# passing (or silently failing to exercise the bug) below.
GLOB_ORDER="$(cd "$TMP/.orchestrate/inbox" && printf '%s\n' 953c-*.md)"
EXPECTED_ORDER=$'953c-impl-do-the-thing.md\n953c-inv-plan-the-thing.md\n953c-verify-confirm-the-thing.md'
if [[ "$GLOB_ORDER" != "$EXPECTED_ORDER" ]]; then
  fail "test precondition broken: glob order was not impl-before-inv-before-verify as expected (got: $GLOB_ORDER) — this test does not exercise the intended race"
fi
bash "$TMP/.orchestrate/bin/drain-inbox.sh" "$TMP" >/dev/null
S3IID="$(awk -F'|' '/953C-INV — Plan the thing/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
S3PID="$(awk -F'|' '/953C-IMPL — Do the thing/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
S3VID="$(awk -F'|' '/953C-VERIFY — Confirm the thing/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$TMP/.orchestrate/project.md")"
S3ITF="$TMP/.orchestrate/tasks/${S3IID}.md"
S3PTF="$TMP/.orchestrate/tasks/${S3PID}.md"
S3VTF="$TMP/.orchestrate/tasks/${S3VID}.md"
if [[ -n "$S3IID" ]] && grep -qE '^depends_on: none$' "$S3ITF" 2>/dev/null; then
  ok "953C-INV has depends_on: none (no blocked_by_ticket header)"
else
  fail "953C-INV unexpectedly has a non-none depends_on:"
fi
if [[ -n "$S3PID" && -n "$S3IID" ]] && grep -qE "^depends_on: ${S3IID}\$" "$S3PTF" 2>/dev/null; then
  ok "953C-IMPL's depends_on: resolved to 953C-INV's real ID ($S3IID) despite impl sorting before inv"
else
  fail "953C-IMPL's depends_on: did NOT resolve to INV's ID (INV=$S3IID IMPL=$S3PID, got: $(grep '^depends_on:' "$S3PTF" 2>/dev/null)) — the IMPL-before-INV alphabetical race regressed"
fi
if [[ -n "$S3VID" && -n "$S3PID" ]] && grep -qE "^depends_on: ${S3PID}\$" "$S3VTF" 2>/dev/null; then
  ok "953C-VERIFY's depends_on: resolved to 953C-IMPL's real ID ($S3PID)"
else
  fail "953C-VERIFY's depends_on: did NOT resolve to IMPL's ID (IMPL=$S3PID VERIFY=$S3VID, got: $(grep '^depends_on:' "$S3VTF" 2>/dev/null))"
fi

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  xfail (known-open, not failing the suite): $XFAIL"
[[ "$XFIXED" -gt 0 ]] && echo "  xfail-now-passing (PROMOTE these): $XFIXED"
echo "──────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED" && exit 1
