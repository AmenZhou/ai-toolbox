#!/usr/bin/env bash
# test-gated-no-token-spend.sh — regression: gated (awaiting_go) tasks consume ZERO
# AI tokens (task AT-3, 20260629-inbox-9D4A). Locks in the AT-1 + AT-2 invariant so a
# future edit cannot silently reintroduce per-cycle gated notification/execution.
#
# Two observable proxies for "no token spend" (no live tend, no agent, no tokens):
#   1. tend-need-action.sh: a registry whose only data rows are `awaiting_go` reports
#      NEED_ACTION=0 (so run-job.sh dispatches no agent). A `pending` row in the same
#      registry MUST flip NEED_ACTION=1 (proves the test detects real work, not a
#      trivially-passing always-0). REGISTRY_ACTIONABLE excludes the gated rows.
#   2. drain-inbox.sh (AT-1): draining a gated file notifies exactly once (osascript,
#      stubbed + counted here) and stamps one .orchestrate/logs/gated-notified.tsv line;
#      a re-drain produces no second notification and no second marker.
#
# Scenario 4 also locks in TNAP-1 (PARTIAL-suffix false-positive fix mirrored from
# finalize-completed-tasks.sh's A4EB fix); scenario 5 locks in 20260725-inbox-DEFR1
# (a (DEFER)-suffixed clean completion must still count as completion-eligible).
#
# Hermetic: fresh mktemp -d root per assertion, cleaned on exit; never touches the
# live .orchestrate/. Follows the sibling test-*.sh style (ok/fail counters).
set -uo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
TEND_NEED_ACTION="${TEND_NEED_ACTION:-$PROJECT_ROOT/bin/tend-need-action.sh}"
DRAIN="${DRAIN:-$PROJECT_ROOT/bin/drain-inbox.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

# --- fixture builders -------------------------------------------------------
seed_root() {
  # $1 = root dir. Creates .orchestrate/{inbox/gated,logs} + a project.md header.
  local root="$1"
  mkdir -p "$root/.orchestrate/inbox/gated" "$root/.orchestrate/logs"
  cat >"$root/.orchestrate/project.md" <<'EOF'
# Orchestrate — test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
EOF
}

add_row() {
  # $1=root $2=id $3=mode $4=status
  printf '| %s | Test task %s | %s | 1 | %s | 2026-01-01T00:00:00Z |\n' \
    "$2" "$2" "$3" "$4" >>"$1/.orchestrate/project.md"
}

need_action() {
  # echo the NEED_ACTION value for the given root
  bash "$TEND_NEED_ACTION" "$1" 2>/dev/null | grep '^NEED_ACTION=' | cut -d= -f2
}
registry_actionable() {
  bash "$TEND_NEED_ACTION" "$1" 2>/dev/null | grep '^REGISTRY_ACTIONABLE=' | cut -d= -f2
}

echo "test-gated-no-token-spend.sh"

# === 1. gated-only registry → NEED_ACTION=0, REGISTRY_ACTIONABLE excludes gated ===
echo ""
echo "1. gated-only registry raises no action (no agent dispatch → zero tokens)"
TMP="$(mktemp -d)"
seed_root "$TMP"
add_row "$TMP" "GATE001" gated awaiting_go
add_row "$TMP" "GATE002" gated awaiting_go
NA="$(need_action "$TMP")"
RA="$(registry_actionable "$TMP")"
[ "$NA" = "0" ] && ok "gated-only → NEED_ACTION=0" || fail "gated-only → NEED_ACTION=$NA (expected 0)"
[ "$RA" = "0" ] && ok "gated rows excluded from REGISTRY_ACTIONABLE ($RA)" || fail "REGISTRY_ACTIONABLE=$RA (expected 0 — gated must not count)"
rm -rf "$TMP"; TMP=""

# === 2. gated + pending → NEED_ACTION=1 (test has teeth) ===
echo ""
echo "2. a pending row alongside gated DOES raise action (detects real work)"
TMP="$(mktemp -d)"
seed_root "$TMP"
add_row "$TMP" "GATE001" gated awaiting_go
add_row "$TMP" "PEND001" auto pending
NA="$(need_action "$TMP")"
RA="$(registry_actionable "$TMP")"
[ "$NA" = "1" ] && ok "gated+pending → NEED_ACTION=1" || fail "gated+pending → NEED_ACTION=$NA (expected 1)"
[ "$RA" = "1" ] && ok "only the pending row counts as actionable ($RA)" || fail "REGISTRY_ACTIONABLE=$RA (expected 1)"
rm -rf "$TMP"; TMP=""

# === 3. drain notifies a gated file exactly once + one marker; re-drain = no-op ===
echo ""
echo "3. drain-inbox.sh notifies a gated file once + one sidecar marker (idempotent)"
TMP="$(mktemp -d)"
seed_root "$TMP"
mkdir -p "$TMP/stub"
cat >"$TMP/stub/osascript" <<EOF
#!/usr/bin/env bash
echo "1" >> "$TMP/notify.count"
exit 0
EOF
chmod +x "$TMP/stub/osascript"
SIDECAR="$TMP/.orchestrate/logs/gated-notified.tsv"
gated_fixture() {
  printf 'gate_reason: live kubectl mutation needs human review\n# Gated fixture\n\n## Goal\nGated thing.\n' \
    >"$TMP/.orchestrate/inbox/gated/g1.md"
}
# auto fixture must NOT notify / mark
printf '# Auto fixture\n\n## Goal\nAuto thing.\n' >"$TMP/.orchestrate/inbox/a1.md"

gated_fixture
PATH="$TMP/stub:$PATH" bash "$DRAIN" "$TMP" >/dev/null 2>&1
N1=$([ -f "$TMP/notify.count" ] && wc -l <"$TMP/notify.count" | tr -d ' ' || echo 0)
S1=$([ -f "$SIDECAR" ] && wc -l <"$SIDECAR" | tr -d ' ' || echo 0)
[ "$N1" = "1" ] && ok "first drain → exactly 1 notification" || fail "first drain → $N1 notifications (expected 1)"
[ "$S1" = "1" ] && ok "first drain → exactly 1 gated-notified.tsv marker" || fail "first drain → $S1 markers (expected 1)"
if [ -f "$SIDECAR" ] && grep -q "Auto fixture" "$SIDECAR" 2>/dev/null; then
  fail "auto file leaked into sidecar"
else
  ok "auto file produced no marker (gated-only)"
fi

# re-seed the SAME gated file and drain again → no second notify / marker
gated_fixture
PATH="$TMP/stub:$PATH" bash "$DRAIN" "$TMP" >/dev/null 2>&1
N2=$(wc -l <"$TMP/notify.count" | tr -d ' ')
S2=$(wc -l <"$SIDECAR" | tr -d ' ')
[ "$N2" = "1" ] && ok "re-drain → no second notification (still 1)" || fail "re-drain → $N2 notifications (expected 1)"
[ "$S2" = "1" ] && ok "re-drain → no second marker (still 1)" || fail "re-drain → $S2 markers (expected 1)"
rm -rf "$TMP"; TMP=""

# === 4. needs_human row with PARTIAL-suffixed complete phases + bypassed_at
#        (TNAP-1 / task 20260725-inbox-CE42 shape) must NOT count as
#        completion-eligible — the un-anchored '✓ complete' substring match
#        previously false-positived on "✓ complete (PARTIAL vs. acceptance...)"
#        lines, waking the agent every cycle for an already-parked human block ===
echo ""
echo "4. needs_human row with PARTIAL-suffixed ✓ complete + bypassed_at is not actionable (TNAP-1 / CE42 shape)"
TMP="$(mktemp -d)"
seed_root "$TMP"
add_row "$TMP" "CE42LIKE" auto needs_human
mkdir -p "$TMP/.orchestrate/tasks"
cat >"$TMP/.orchestrate/tasks/CE42LIKE.md" <<'EOF'
id: CE42LIKE
task: fixture mirroring 20260725-inbox-CE42
total_phases: 2

### Phase 1: Author [inline · execution]
status: ✓ complete (PARTIAL vs. acceptance — see phase log)
depends_on: none

### Phase 2: Test & Verify [inline · execution]
status: ✓ complete (PARTIAL vs. acceptance — live-location criterion pending human install)
depends_on: [1]

bypassed_at: 2026-07-25T06:15:13Z
bypass_reason: churn-prevention park — blocked_on:EXTERNAL confirmed twice

## Human-only block (confirmed, not locally resolvable)
blocked_on: EXTERNAL
EOF
NA="$(need_action "$TMP")"
RA="$(registry_actionable "$TMP")"
NHA="$(bash "$TEND_NEED_ACTION" "$TMP" 2>/dev/null | grep '^NEEDS_HUMAN_ACTIONABLE=' | cut -d= -f2)"
[ "$NHA" = "0" ] && ok "PARTIAL-suffixed + bypassed_at → NEEDS_HUMAN_ACTIONABLE=0" || fail "NEEDS_HUMAN_ACTIONABLE=$NHA (expected 0 — false-positive completion-eligible)"
[ "$RA" = "0" ] && ok "REGISTRY_ACTIONABLE excludes the parked block ($RA)" || fail "REGISTRY_ACTIONABLE=$RA (expected 0)"
[ "$NA" = "0" ] && ok "no other work → NEED_ACTION=0 (no wasted agent dispatch)" || fail "NEED_ACTION=$NA (expected 0)"
rm -rf "$TMP"; TMP=""

# === 5. needs_human row with a single-line (DEFER) suffix on the LAST phase
#        counts as completion-eligible, not "not yet evaluated" (20260725-inbox-DEFR1)
#        — count_needs_human_actionable()'s done_phases regex previously required
#        nothing after "complete", so a real, clean `(DEFER)`-suffixed completion
#        (task 20260724-inbox-7496 precedent) was never counted as done: it fell
#        through to the "not yet evaluated" branch and triggered a spurious
#        first-pass auto-resolution check every cycle instead of being recognized
#        as finalize-eligible ===
echo ""
echo "5. needs_human row with (DEFER)-suffixed final phase counts as completion-eligible (DEFR1 / 7496 shape)"
TMP="$(mktemp -d)"
seed_root "$TMP"
add_row "$TMP" "DEFR1LIKE" auto needs_human
mkdir -p "$TMP/.orchestrate/tasks"
cat >"$TMP/.orchestrate/tasks/DEFR1LIKE.md" <<'EOF'
id: DEFR1LIKE
task: fixture mirroring 20260724-inbox-7496's (DEFER) shape
total_phases: 2

### Phase 1: Author [inline · execution]
status: ✓ complete
depends_on: none

### Phase 2: Defer path [inline · execution]
status: ✓ complete (DEFER path)
depends_on: [1]
EOF
NHA="$(bash "$TEND_NEED_ACTION" "$TMP" 2>/dev/null | grep '^NEEDS_HUMAN_ACTIONABLE=' | cut -d= -f2)"
[ "$NHA" = "1" ] && ok "(DEFER path)-suffixed row counted as completion-eligible → NEEDS_HUMAN_ACTIONABLE=1" || fail "NEEDS_HUMAN_ACTIONABLE=$NHA (expected 1 — DEFER suffix should count as done)"
rm -rf "$TMP"; TMP=""

# --- results ----------------------------------------------------------------
echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  echo "  ALL TESTS PASSED"
  exit 0
fi
echo "  SOME TESTS FAILED"
exit 1
