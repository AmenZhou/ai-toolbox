#!/usr/bin/env bash
# test-enqueue-review-tests.sh — dry-run regression for OR-1/OR-2/OR-3
# (auto-enqueue review + tests follow-ups on completion).
#
# The feature is "enforce a review + a test pass for every code change", so it
# ships with its own tests (dogfooding). Every scenario runs against a fresh
# `mktemp -d` control plane — NEVER the live inbox. The finalize path is exercised
# end-to-end (finalize-completed-tasks.sh → enqueue-review-and-tests.sh) so the
# wiring (OR-2) and the helper (OR-1) are both covered.
#
# Scenarios:
#   A happy path  — completed code-changing task → exactly 1 kind:review +
#                   1 kind:tests ticket, both auto (no gate_reason)
#   B anti-recur. — a `followup_for:` source task completing → 0 new tickets
#   C idempotency — re-running finalize/enqueue for the same ID → 0 additional
#   D no-op       — docs/log-only task → 0 tickets
#   E double-drain — re-draining a followup with an existing pair in processed/
#                    or history/ does not register a new registry row
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
BIN="$PROJECT_ROOT/bin"
HELPER="${HELPER:-$BIN/enqueue-review-and-tests.sh}"
FINALIZE="${FINALIZE:-$BIN/finalize-completed-tasks.sh}"
DRAIN="${DRAIN:-$BIN/drain-inbox.sh}"
DEDUP="${DEDUP:-$BIN/followup-dedup.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

OLD_TS="2026-06-28T01:00:00Z"

# Build a control plane with a copy of the enqueue helper inside it (finalize
# resolves the helper at $ROOT/.orchestrate/bin/) so writes stay hermetic.
build_cp() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/.orchestrate/tasks" "$T/.orchestrate/logs" \
           "$T/.orchestrate/inbox/gated" "$T/.orchestrate/inbox/processed" \
           "$T/.orchestrate/bin" "$T/orchestrate-history"
  cp "$HELPER" "$T/.orchestrate/bin/enqueue-review-and-tests.sh"
  cp "$DEDUP" "$T/.orchestrate/bin/followup-dedup.sh"
  cp "$DRAIN" "$T/.orchestrate/bin/drain-inbox.sh"
  chmod +x "$T/.orchestrate/bin/"*.sh
  : > "$T/orchestrate-history/MANIFEST.md"
  printf '%s' "$T"
}

# Seed a registry with a single running row.
seed_registry() {
  local T="$1" row="$2"
  {
    echo "# Project"
    echo "## Task Registry"
    echo "| ID | Summary | Mode | Phase | Status | Last Activity |"
    echo "|----|---------|------|-------|--------|---------------|"
    echo "$row"
  } > "$T/.orchestrate/project.md"
}

inbox_count() { ls "$1/.orchestrate/inbox"/*.md 2>/dev/null | wc -l | tr -d ' '; }
header_count() { grep -lE "^kind:[[:space:]]*$2" "$1/.orchestrate/inbox"/*.md 2>/dev/null | wc -l | tr -d ' '; }
gatereason_count() { grep -lE '^gate_reason:' "$1/.orchestrate/inbox"/*.md 2>/dev/null | wc -l | tr -d ' '; }

echo "── test-enqueue-review-tests ───────────────────────"

# ── Scenario A — happy path ─────────────────────────────────────────────────
A="$(build_cp)"
seed_registry "$A" "| 20260629-codeA | add a helper | auto | 1 | running | $OLD_TS |"
printf '%s\n' \
  "# Task: add a helper" "id: 20260629-codeA" "total_phases: 1" \
  "files_changed: [.orchestrate/bin/widget.sh, README.md]" \
  "### Phase 1" "status: ✓ complete" \
  > "$A/.orchestrate/tasks/20260629-codeA.md"
bash "$FINALIZE" "$A" >/dev/null 2>&1
[ "$(inbox_count "$A")" = "2" ] && ok "A: code task enqueues exactly 2 tickets" || fail "A: expected 2 tickets, got $(inbox_count "$A")"
[ "$(header_count "$A" review)" = "1" ] && ok "A: exactly 1 kind:review" || fail "A: review count = $(header_count "$A" review)"
[ "$(header_count "$A" tests)" = "1" ]  && ok "A: exactly 1 kind:tests"  || fail "A: tests count = $(header_count "$A" tests)"
[ "$(gatereason_count "$A")" = "0" ] && ok "A: tickets are auto (no gate_reason)" || fail "A: $(gatereason_count "$A") ticket(s) carry gate_reason"
grep -lE '^followup_for:[[:space:]]*20260629-codeA' "$A/.orchestrate/inbox"/*.md >/dev/null 2>&1 \
  && ok "A: followup_for header present" || fail "A: missing followup_for header"

# ── Scenario B — anti-recursion ─────────────────────────────────────────────
B="$(build_cp)"
seed_registry "$B" "| 20260629-fuB | tests for codeA | auto | 1 | running | $OLD_TS |"
printf '%s\n' \
  "followup_for: 20260629-codeA" "kind: tests" \
  "# Task: tests for codeA" "id: 20260629-fuB" "total_phases: 1" \
  "files_changed: [test_widget.sh]" \
  "### Phase 1" "status: ✓ complete" \
  > "$B/.orchestrate/tasks/20260629-fuB.md"
bash "$FINALIZE" "$B" >/dev/null 2>&1
[ "$(inbox_count "$B")" = "0" ] && ok "B: followup_for task enqueues nothing (anti-recursion)" || fail "B: expected 0, got $(inbox_count "$B")"

# ── Scenario C — idempotency ────────────────────────────────────────────────
C="$(build_cp)"
seed_registry "$C" "| 20260629-codeC | add another helper | auto | 1 | running | $OLD_TS |"
printf '%s\n' \
  "# Task: add another helper" "id: 20260629-codeC" "total_phases: 1" \
  "files_changed: [.orchestrate/bin/gadget.sh]" \
  "### Phase 1" "status: ✓ complete" \
  > "$C/.orchestrate/tasks/20260629-codeC.md"
# First finalize writes 2 tickets and deletes the task file. Re-run the enqueue
# helper directly (task file gone) — dedup must keep the count at 2.
bash "$FINALIZE" "$C" >/dev/null 2>&1
first="$(inbox_count "$C")"
ENQ_ROOT="$C" ENQ_INBOX_ROOT="$C" bash "$HELPER" 20260629-codeC >/dev/null 2>&1 || true
second="$(inbox_count "$C")"
[ "$first" = "2" ] && [ "$second" = "2" ] && ok "C: re-run is idempotent (2 → 2, no duplicates)" || fail "C: count changed $first → $second"

# ── Scenario D — no-op (docs/log only) ──────────────────────────────────────
D="$(build_cp)"
seed_registry "$D" "| 20260629-docD | update the docs | auto | 1 | running | $OLD_TS |"
printf '%s\n' \
  "# Task: update the docs" "id: 20260629-docD" "total_phases: 1" \
  "files_changed: [README.md, .orchestrate/logs/x.log]" \
  "### Phase 1" "status: ✓ complete" \
  > "$D/.orchestrate/tasks/20260629-docD.md"
bash "$FINALIZE" "$D" >/dev/null 2>&1
[ "$(inbox_count "$D")" = "0" ] && ok "D: docs/log-only task enqueues nothing" || fail "D: expected 0, got $(inbox_count "$D")"

# ── Scenario E — double-drain dedup ─────────────────────────────────────────
E="$(build_cp)"
seed_registry "$E" "| 20260629-codeE | parent task | auto | 1 | complete | $OLD_TS |"
# Prior drain left the pair in processed/
cat > "$E/.orchestrate/inbox/processed/followup-review-20260629-codeE-stamp1.md" <<'EOF'
followup_for: 20260629-codeE
kind: review
mode: auto
source: self

# Review of parent task
EOF
# Completed follow-up archived in history (same pair)
cat > "$E/orchestrate-history/20260629-010000-20260629-revE-review.md" <<'EOF'
followup_for: 20260629-codeE
kind: review
id: 20260629-revE
### Phase 1
status: ✓ complete
EOF
rows_before="$(grep -cE '^\|[[:space:]]*20260629' "$E/.orchestrate/project.md" || true)"
# Stale re-appearance in root inbox (new stamp, same pair)
cat > "$E/.orchestrate/inbox/followup-review-20260629-codeE-stamp2.md" <<'EOF'
followup_for: 20260629-codeE
kind: review
mode: auto
source: self

# Review of parent task
EOF
bash "$DRAIN" "$E" >/dev/null 2>&1
rows_after="$(grep -cE '^\|[[:space:]]*20260629' "$E/.orchestrate/project.md" || true)"
[ "$rows_before" = "$rows_after" ] && ok "E: double-drain does not add a new registry row" || fail "E: registry grew $rows_before → $rows_after"
[ ! -f "$E/.orchestrate/inbox/followup-review-20260629-codeE-stamp2.md" ] && ok "E: stale followup moved out of root inbox" || fail "E: stale followup still in root inbox"
grep -q 'skipped (dedup followup_for=20260629-codeE kind=review)' "$E/.orchestrate/logs/heartbeat.log" 2>/dev/null \
  && ok "E: heartbeat logs dedup skip" || fail "E: missing dedup skip heartbeat line"

# ── Scenario F — archive fallback (model-path deletes task file first) ───────
# The model-path Completion sequence deletes the LIVE task file (step 1) before
# the 6b enqueue (step 6b) runs. The helper must fall back to the archived copy
# in orchestrate-history/ so a genuine code change still enqueues review+tests.
F="$(build_cp)"
seed_registry "$F" "| 20260629-codeF | add a helper (archived) | auto | 1 | complete | $OLD_TS |"
# No live task file — only the archived copy exists (mirrors post-deletion state).
cat > "$F/orchestrate-history/20260629-020000-20260629-codeF-add-helper.md" <<'EOF'
# Task: add a helper (archived)
id: 20260629-codeF
total_phases: 1
files_changed: [.orchestrate/bin/sprocket.sh, README.md]
### Phase 1
status: ✓ complete
EOF
[ ! -f "$F/.orchestrate/tasks/20260629-codeF.md" ] || fail "F: live task file should be absent"
ENQ_ROOT="$F" ENQ_INBOX_ROOT="$F" bash "$HELPER" 20260629-codeF >/dev/null 2>&1 || true
[ "$(inbox_count "$F")" = "2" ] && ok "F: archive fallback enqueues 2 tickets when live task file is gone" || fail "F: expected 2 tickets, got $(inbox_count "$F")"
[ "$(header_count "$F" review)" = "1" ] && ok "F: exactly 1 kind:review from archive" || fail "F: review count = $(header_count "$F" review)"
[ "$(header_count "$F" tests)" = "1" ]  && ok "F: exactly 1 kind:tests from archive"  || fail "F: tests count = $(header_count "$F" tests)"

# ── Scenario G — phase-log fallback (files_changed only in the phase LOG) ────
# The inline model-path Completion sometimes records the aggregate
# files_changed: ONLY in .orchestrate/logs/{ID}-phaseN.log — the task file/archive
# phase blocks carry only summary:/acceptance_criteria. The helper must fall back
# to scanning the phase logs so a genuine code change still enqueues review+tests.
G="$(build_cp)"
seed_registry "$G" "| 20260629-codeG | phase-log only | auto | 1 | complete | $OLD_TS |"
printf '%s\n' \
  "# Task: phase-log only" "id: 20260629-codeG" "total_phases: 1" \
  "### Phase 1" "status: ✓ complete" "summary: did a thing" \
  > "$G/.orchestrate/tasks/20260629-codeG.md"
# No files_changed: in the task file — it lives only in the phase log.
printf '%s\n' "files_changed: [.orchestrate/bin/cog.sh, README.md]" \
  > "$G/.orchestrate/logs/20260629-codeG-phase1.log"
grep -qE '^files_changed:' "$G/.orchestrate/tasks/20260629-codeG.md" \
  && fail "G: precondition — task file should have NO files_changed line" \
  || ok "G: precondition — task file has no files_changed line"
ENQ_ROOT="$G" ENQ_INBOX_ROOT="$G" bash "$HELPER" 20260629-codeG >/dev/null 2>&1 || true
[ "$(inbox_count "$G")" = "2" ] && ok "G: phase-log files_changed fallback enqueues 2 tickets" || fail "G: expected 2 tickets, got $(inbox_count "$G")"
[ "$(header_count "$G" review)" = "1" ] && ok "G: exactly 1 kind:review from phase-log fallback" || fail "G: review count = $(header_count "$G" review)"
[ "$(header_count "$G" tests)" = "1" ]  && ok "G: exactly 1 kind:tests from phase-log fallback"  || fail "G: tests count = $(header_count "$G" tests)"

# ── Scenario H — phase-log docs-only (predicate still filters) ───────────────
# A phase log listing ONLY docs (*.md) must still yield NO enqueue: the fallback
# feeds the same is_code_change predicate, so pure docs are filtered out.
H="$(build_cp)"
seed_registry "$H" "| 20260629-docH | phase-log docs only | auto | 1 | complete | $OLD_TS |"
printf '%s\n' \
  "# Task: phase-log docs only" "id: 20260629-docH" "total_phases: 1" \
  "### Phase 1" "status: ✓ complete" "summary: wrote docs" \
  > "$H/.orchestrate/tasks/20260629-docH.md"
printf '%s\n' "files_changed: [README.md, docs/guide.md]" \
  > "$H/.orchestrate/logs/20260629-docH-phase1.log"
ENQ_ROOT="$H" ENQ_INBOX_ROOT="$H" bash "$HELPER" 20260629-docH >/dev/null 2>&1 || true
[ "$(inbox_count "$H")" = "0" ] && ok "H: docs-only phase-log still enqueues nothing (predicate filters)" || fail "H: expected 0, got $(inbox_count "$H")"

# ── Scenario I — wiki-ingest state-JSON false-positive (3D8E) ─────────────────
# orchestrate-daily-wiki-ingest changes only wiki .md pages + a bare-or-path
# wiki-ingest-state.json + a *-daily.log — zero code. A bare `wiki-ingest-state.json`
# token used to fall through to the `*.json) found=0` branch and spuriously enqueue
# review+tests. The `*-state.json` exclusion must make the whole set no-code.
I_BARE="$(build_cp)"
seed_registry "$I_BARE" "| 20260703-wikiI | daily wiki ingest (bare state) | auto | 1 | complete | $OLD_TS |"
printf '%s\n' \
  "# Task: daily wiki ingest" "id: 20260703-wikiI" "total_phases: 1" \
  "files_changed: [obsidian/a.md, obsidian/b.md, wiki-ingest-state.json, wiki-ingest-daily.log]" \
  "### Phase 1" "status: ✓ complete" \
  > "$I_BARE/.orchestrate/tasks/20260703-wikiI.md"
ENQ_ROOT="$I_BARE" ENQ_INBOX_ROOT="$I_BARE" bash "$HELPER" 20260703-wikiI >/dev/null 2>&1 || true
[ "$(inbox_count "$I_BARE")" = "0" ] && ok "I: bare wiki-ingest-state.json set enqueues nothing" || fail "I: expected 0, got $(inbox_count "$I_BARE")"

# Same set but path-qualified state file — must also be no-code.
I_PATH="$(build_cp)"
seed_registry "$I_PATH" "| 20260703-wikiIp | daily wiki ingest (path state) | auto | 1 | complete | $OLD_TS |"
printf '%s\n' \
  "# Task: daily wiki ingest" "id: 20260703-wikiIp" "total_phases: 1" \
  "files_changed: [obsidian/a.md, .orchestrate/logs/wiki-ingest-state.json, .orchestrate/logs/wiki-ingest-daily.log]" \
  "### Phase 1" "status: ✓ complete" \
  > "$I_PATH/.orchestrate/tasks/20260703-wikiIp.md"
ENQ_ROOT="$I_PATH" ENQ_INBOX_ROOT="$I_PATH" bash "$HELPER" 20260703-wikiIp >/dev/null 2>&1 || true
[ "$(inbox_count "$I_PATH")" = "0" ] && ok "I: path-qualified wiki-ingest-state.json set enqueues nothing" || fail "I: expected 0, got $(inbox_count "$I_PATH")"

# Guard: a REAL code file alongside a state.json still enqueues (exclusion is narrow).
I_CODE="$(build_cp)"
seed_registry "$I_CODE" "| 20260703-wikiIc | code + state | auto | 1 | complete | $OLD_TS |"
printf '%s\n' \
  "# Task: code plus state" "id: 20260703-wikiIc" "total_phases: 1" \
  "files_changed: [.orchestrate/bin/foo.sh, wiki-ingest-state.json]" \
  "### Phase 1" "status: ✓ complete" \
  > "$I_CODE/.orchestrate/tasks/20260703-wikiIc.md"
ENQ_ROOT="$I_CODE" ENQ_INBOX_ROOT="$I_CODE" bash "$HELPER" 20260703-wikiIc >/dev/null 2>&1 || true
[ "$(inbox_count "$I_CODE")" = "2" ] && ok "I: real code file alongside state.json still enqueues 2" || fail "I: expected 2, got $(inbox_count "$I_CODE")"

# ── Scenario J — no files_changed source ANYWHERE → distinct WARN (9CB1) ──────
# A completed CODE task whose live task file was deleted (Completion step 1), whose
# archive copy carries NO files_changed: line, and with no phase log, yields an
# EMPTY collect_files. That used to fall into the same quiet "no code change" skip
# as a docs-only task — silently swallowing a missed review+tests enforcement.
# The helper must now emit a DISTINCT heartbeat WARN so the miss is auditable.
J="$(build_cp)"
seed_registry "$J" "| 20260703-codeJ | no files_changed anywhere | auto | 1 | complete | $OLD_TS |"
# No live task file; archived copy exists but carries NO files_changed: line; no phase log.
cat > "$J/orchestrate-history/20260703-030000-20260703-codeJ-mystery.md" <<'EOF'
# Task: no files_changed anywhere
id: 20260703-codeJ
total_phases: 1
### Phase 1
status: ✓ complete
summary: did something but never recorded files_changed
EOF
[ ! -f "$J/.orchestrate/tasks/20260703-codeJ.md" ] || fail "J: live task file should be absent"
ENQ_ROOT="$J" ENQ_INBOX_ROOT="$J" bash "$HELPER" 20260703-codeJ >/dev/null 2>&1 || true
[ "$(inbox_count "$J")" = "0" ] && ok "J: absent files_changed source enqueues nothing" || fail "J: expected 0, got $(inbox_count "$J")"
grep -q "enqueue — WARN 20260703-codeJ: completed task has no files_changed source" "$J/.orchestrate/logs/heartbeat.log" 2>/dev/null \
  && ok "J: distinct WARN heartbeat line emitted for missing files_changed source" || fail "J: missing WARN heartbeat line"
# Guard: a docs-only task (files_changed PRESENT but all docs) must NOT emit the WARN — stays quiet.
J2="$(build_cp)"
seed_registry "$J2" "| 20260703-docJ2 | docs only present | auto | 1 | complete | $OLD_TS |"
printf '%s\n' \
  "# Task: docs only present" "id: 20260703-docJ2" "total_phases: 1" \
  "files_changed: [README.md, docs/x.md]" \
  "### Phase 1" "status: ✓ complete" \
  > "$J2/.orchestrate/tasks/20260703-docJ2.md"
ENQ_ROOT="$J2" ENQ_INBOX_ROOT="$J2" bash "$HELPER" 20260703-docJ2 >/dev/null 2>&1 || true
[ "$(inbox_count "$J2")" = "0" ] && ok "J: docs-only (files_changed present) enqueues nothing" || fail "J: docs-only expected 0, got $(inbox_count "$J2")"
grep -q "enqueue — WARN 20260703-docJ2" "$J2/.orchestrate/logs/heartbeat.log" 2>/dev/null \
  && fail "J: docs-only must NOT emit the missing-source WARN (quiet skip preserved)" \
  || ok "J: docs-only takes the quiet skip, no WARN (legit behavior preserved)"

# ── Scenario K — malformed ID rejected before path construction (20260724-inbox-6D91) ─
K="$(build_cp)"
for BAD_ID in "../../etc/passwd" "bad id" "bad;id"; do
  set +e
  ENQ_ROOT="$K" ENQ_INBOX_ROOT="$K" bash "$HELPER" "$BAD_ID" >/tmp/enq-rt-out.$$ 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "K: malformed ID '$BAD_ID' rejected (exit $rc)" || fail "K: malformed ID '$BAD_ID' should have been rejected, exited 0"
  grep -qi 'invalid' /tmp/enq-rt-out.$$ && ok "K: malformed ID '$BAD_ID' error message is clear" || fail "K: malformed ID '$BAD_ID' produced no clear error message"
done
[ ! -e "$K/etc" ] && ok "K: no path-traversal write occurred (no $K/etc created)" || fail "K: path traversal write occurred: $K/etc exists"
[ "$(inbox_count "$K")" = "0" ] && ok "K: no ticket written for any malformed ID" || fail "K: expected 0 tickets, got $(inbox_count "$K")"
rm -f /tmp/enq-rt-out.$$

echo ""
echo "  test-enqueue-review-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
