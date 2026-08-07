#!/usr/bin/env bash
# test-enqueue-wiki-sync.sh — dry-run regression for enqueue-wiki-sync.sh
# (auto-enqueue a wiki-sync follow-up for EVERY completed task, subject only
# to the two anti-recursion guards — WS-1, broadened by WIKI-1 2026-07-25 to
# drop the prior code-change/research-keyword gate).
#
# Mirrors test-enqueue-review-tests.sh's harness style: every scenario runs
# against a fresh `mktemp -d` control plane — NEVER the live inbox.
#
# Scenarios (from the original ticket's ACs, B updated by WIKI-1):
#   A zero-code       — docs-only files_changed → exactly 1 kind:wiki-sync
#                        ticket with correct headers
#   B code, no match  — >=1 code file, no research keyword → STILL fires
#                        exactly 1 ticket, exits 0 (WIKI-1: no longer gated)
#   C anti-recursion   — followup_for: already set → nothing enqueued, exits 0
#   D idempotency      — re-running against the same task → no duplicate
#   E code + research tag → still fires (same as any other code-change task
#                        post-WIKI-1, kept to confirm the tag doesn't disable it)
#   F wiki-job skip    — title matches a wiki-* job itself → nothing
#                        enqueued, exits 0 (anti-recursion)
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
BIN="$PROJECT_ROOT/bin"
HELPER="${HELPER:-$BIN/enqueue-wiki-sync.sh}"
DEDUP="${DEDUP:-$BIN/followup-dedup.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# Build a hermetic control plane with a copy of the helper + its dedup
# dependency inside it (mirrors ENQ_ROOT resolving $ROOT/.orchestrate/bin/).
build_cp() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/.orchestrate/tasks" "$T/.orchestrate/logs" \
           "$T/.orchestrate/inbox/gated" "$T/.orchestrate/inbox/processed" \
           "$T/.orchestrate/bin" "$T/orchestrate-history"
  cp "$HELPER" "$T/.orchestrate/bin/enqueue-wiki-sync.sh"
  cp "$DEDUP" "$T/.orchestrate/bin/followup-dedup.sh"
  : > "$T/orchestrate-history/MANIFEST.md"
  printf '%s' "$T"
}

run_helper() {
  local T="$1" id="$2"
  ENQ_ROOT="$T" ENQ_INBOX_ROOT="$T" bash "$T/.orchestrate/bin/enqueue-wiki-sync.sh" "$id"
}

inbox_count()  { ls "$1/.orchestrate/inbox"/*.md 2>/dev/null | wc -l | tr -d ' '; }
kind_count()   { grep -lE "^kind:[[:space:]]*$2([[:space:]]|\$)" "$1/.orchestrate/inbox"/*.md 2>/dev/null | wc -l | tr -d ' '; }

echo "── test-enqueue-wiki-sync ───────────────────────"

# ── Scenario A — zero-code task → exactly 1 kind:wiki-sync ticket ───────────
A="$(build_cp)"
printf '%s\n' \
  "# Task: investigate the redis blocker" "id: 20260717-wsA" "total_phases: 1" \
  "files_changed: [obsidian/notes.md]" \
  "### Phase 1" "status: ✓ complete" \
  > "$A/.orchestrate/tasks/20260717-wsA.md"
set +e
run_helper "$A" 20260717-wsA >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] && ok "A: zero-code task exits 0" || fail "A: expected exit 0, got $rc"
[ "$(inbox_count "$A")" = "1" ] && ok "A: exactly 1 ticket written" || fail "A: expected 1 ticket, got $(inbox_count "$A")"
[ "$(kind_count "$A" wiki-sync)" = "1" ] && ok "A: ticket carries kind:wiki-sync" || fail "A: kind:wiki-sync count = $(kind_count "$A" wiki-sync)"
fname="$(ls "$A/.orchestrate/inbox"/followup-wiki-sync-20260717-wsA-*.md 2>/dev/null | head -1)"
[ -n "$fname" ] && ok "A: filename matches followup-wiki-sync-<ID>-<stamp>.md" || fail "A: no matching ticket filename found"
if [ -n "$fname" ]; then
  grep -q '^followup_for: 20260717-wsA' "$fname" && ok "A: followup_for header correct" || fail "A: missing/incorrect followup_for header"
  grep -q '^mode: auto' "$fname" && ok "A: mode: auto header present" || fail "A: missing mode: auto header"
  grep -q '^source: self' "$fname" && ok "A: source: self header present" || fail "A: missing source: self header"
  grep -qE '^gate_reason:' "$fname" && fail "A: ticket unexpectedly carries gate_reason (should be auto)" || ok "A: no gate_reason (stays auto/pending)"
fi

# ── Scenario B — >=1 code file, no research keyword → STILL fires (WIKI-1) ───
B="$(build_cp)"
printf '%s\n' \
  "# Task: fix the widget bug" "id: 20260717-wsB" "total_phases: 1" \
  "files_changed: [.orchestrate/bin/widget.sh]" \
  "### Phase 1" "status: ✓ complete" \
  > "$B/.orchestrate/tasks/20260717-wsB.md"
set +e
run_helper "$B" 20260717-wsB >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] && ok "B: code-change/no-keyword task exits 0 (fires, WIKI-1)" || fail "B: expected exit 0, got $rc"
[ "$(inbox_count "$B")" = "1" ] && ok "B: code-change/no-keyword task still enqueues 1 ticket" || fail "B: expected 1 ticket, got $(inbox_count "$B")"

# ── Scenario C — followup_for: already set → nothing, exit 0 (anti-recursion) ─
C="$(build_cp)"
printf '%s\n' \
  "followup_for: 20260717-wsA" \
  "# Task: tests for the investigate task" "id: 20260717-wsC" "total_phases: 1" \
  "files_changed: [obsidian/notes.md]" \
  "### Phase 1" "status: ✓ complete" \
  > "$C/.orchestrate/tasks/20260717-wsC.md"
set +e
run_helper "$C" 20260717-wsC >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] && ok "C: followup_for task exits 0" || fail "C: expected exit 0, got $rc"
[ "$(inbox_count "$C")" = "0" ] && ok "C: followup_for task enqueues nothing (anti-recursion)" || fail "C: expected 0 tickets, got $(inbox_count "$C")"

# ── Scenario D — idempotency: re-running does not produce a duplicate ────────
D="$(build_cp)"
printf '%s\n' \
  "# Task: audit the auth flow" "id: 20260717-wsD" "total_phases: 1" \
  "files_changed: [obsidian/audit.md]" \
  "### Phase 1" "status: ✓ complete" \
  > "$D/.orchestrate/tasks/20260717-wsD.md"
run_helper "$D" 20260717-wsD >/dev/null 2>&1 || true
first="$(inbox_count "$D")"
set +e
run_helper "$D" 20260717-wsD >/dev/null 2>&1
rc=$?
set -e
second="$(inbox_count "$D")"
[ "$first" = "1" ] && [ "$second" = "1" ] && ok "D: re-run is idempotent (1 → 1, no duplicates)" || fail "D: count changed $first → $second"
[ "$rc" = "0" ] && ok "D: dedup re-run exits 0" || fail "D: expected exit 0 on dedup re-run, got $rc"

# ── Scenario E — research-keyword-tagged task WITH code changes still fires ──
# (post-WIKI-1 this is no different from B — kept to confirm the research tag
# doesn't accidentally disable the trigger now that it no longer gates it.)
E="$(build_cp)"
printf '%s\n' \
  "# Task: fix the widget bug" "id: 20260717-wsE" "tags: research, followup" "total_phases: 1" \
  "files_changed: [.orchestrate/bin/widget.sh]" \
  "### Phase 1" "status: ✓ complete" \
  > "$E/.orchestrate/tasks/20260717-wsE.md"
set +e
run_helper "$E" 20260717-wsE >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] && ok "E: code change + research tag exits 0 (fires, same as any task)" || fail "E: expected exit 0, got $rc"
[ "$(inbox_count "$E")" = "1" ] && ok "E: code change + research tag still enqueues 1 ticket" || fail "E: expected 1 ticket, got $(inbox_count "$E")"

# ── Scenario F — source task IS a wiki-* job itself → nothing, exit 0 ────────
F="$(build_cp)"
printf '%s\n' \
  "# Task: wiki-ingest daily batch run" "id: 20260717-wsF" "total_phases: 1" \
  "files_changed: [obsidian/page.md]" \
  "### Phase 1" "status: ✓ complete" \
  > "$F/.orchestrate/tasks/20260717-wsF.md"
set +e
run_helper "$F" 20260717-wsF >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] && ok "F: wiki-* job task exits 0" || fail "F: expected exit 0, got $rc"
[ "$(inbox_count "$F")" = "0" ] && ok "F: wiki-* job task enqueues nothing (anti-recursion)" || fail "F: expected 0 tickets, got $(inbox_count "$F")"

# Guard: orchestrate-daily-wiki-ingest / daily-wiki-digest / wiki-capture /
# wiki-update titles must also be excluded (not just wiki-ingest).
for slug in "orchestrate-daily-wiki-ingest run" "daily-wiki-digest for today" "wiki-capture this conversation" "wiki-update the project notes"; do
  FX="$(build_cp)"
  idsafe="wsF$(echo "$slug" | tr -cd '[:alnum:]' | cut -c1-6)"
  printf '%s\n' \
    "# Task: ${slug}" "id: 20260717-${idsafe}" "total_phases: 1" \
    "files_changed: [obsidian/page.md]" \
    "### Phase 1" "status: ✓ complete" \
    > "$FX/.orchestrate/tasks/20260717-${idsafe}.md"
  set +e
  run_helper "$FX" "20260717-${idsafe}" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" = "0" ] && [ "$(inbox_count "$FX")" = "0" ] \
    && ok "F: '$slug' excluded (anti-recursion)" \
    || fail "F: '$slug' expected exit 0 / 0 tickets, got rc=$rc count=$(inbox_count "$FX")"
done

# ── Scenario G — dedup pair already satisfied in orchestrate-history/ only ───
# (not re-run-in-place like D — the pair was archived by a prior drain/finalize
# cycle and never sat in the live inbox at all). Exercises the documented
# "anywhere" search in followup_pair_exists() (inbox/gated/processed/tasks/
# history), not just the trivial same-directory re-run covered by D.
G="$(build_cp)"
printf '%s\n' \
  "# Task: audit the auth flow" "id: 20260717-wsG" "total_phases: 1" \
  "files_changed: [obsidian/audit.md]" \
  "### Phase 1" "status: ✓ complete" \
  > "$G/.orchestrate/tasks/20260717-wsG.md"
cat > "$G/orchestrate-history/20260717-000000-20260717-wsG-audit.md" <<'EOF'
followup_for: 20260717-wsG
kind: wiki-sync
EOF
set +e
run_helper "$G" 20260717-wsG >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] && ok "G: history-only pair exits 0" || fail "G: expected exit 0, got $rc"
[ "$(inbox_count "$G")" = "0" ] && ok "G: history-only pair enqueues nothing (dedup beyond same-run re-check)" || fail "G: expected 0 tickets, got $(inbox_count "$G")"

# ── Scenario H — malformed ID rejected before path construction (20260724-inbox-6D91) ─
H="$(build_cp)"
for BAD_ID in "../../etc/passwd" "bad id" "bad;id"; do
  set +e
  ENQ_ROOT="$H" ENQ_INBOX_ROOT="$H" bash "$H/.orchestrate/bin/enqueue-wiki-sync.sh" "$BAD_ID" >/tmp/enq-ws-out.$$ 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "H: malformed ID '$BAD_ID' rejected (exit $rc)" || fail "H: malformed ID '$BAD_ID' should have been rejected, exited 0"
  grep -qi 'invalid' /tmp/enq-ws-out.$$ && ok "H: malformed ID '$BAD_ID' error message is clear" || fail "H: malformed ID '$BAD_ID' produced no clear error message"
done
[ ! -e "$H/etc" ] && ok "H: no path-traversal write occurred (no $H/etc created)" || fail "H: path traversal write occurred: $H/etc exists"
[ "$(inbox_count "$H")" = "0" ] && ok "H: no ticket written for any malformed ID" || fail "H: expected 0 tickets, got $(inbox_count "$H")"
rm -f /tmp/enq-ws-out.$$

echo ""
echo "  test-enqueue-wiki-sync: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
