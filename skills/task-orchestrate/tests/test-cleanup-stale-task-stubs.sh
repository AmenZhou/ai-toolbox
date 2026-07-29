#!/usr/bin/env bash
# test-cleanup-stale-task-stubs.sh — cleanup-stale-inbox.sh: orphaned
# churn-guard park stub removal.
#
# A churn-guard park stub (`# {ID} — parked by churn guard`, no `### Phase`
# sections) whose registry row has disappeared entirely (not just gone
# complete) should be removed. A stub still backed by a live registry row
# (any status) must be left in place.
set -uo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found" >&2; exit 1; }
CLEANUP="${CLEANUP:-$PROJECT_ROOT/bin/cleanup-stale-inbox.sh}"
CLEANUP_SRC="${CLEANUP_SRC:-/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/bin/cleanup-stale-inbox.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

echo ""
echo "── cleanup-stale-inbox.sh — orphaned churn-guard stub removal — test suite ───"

echo ""
echo "0. Prerequisites"
[[ -f "$CLEANUP" ]] && ok "cleanup-stale-inbox.sh found" || { fail "cleanup-stale-inbox.sh missing at $CLEANUP"; exit 1; }
if [[ -f "$CLEANUP_SRC" ]] && cmp -s "$CLEANUP_SRC" "$CLEANUP" 2>/dev/null; then
  ok "installed cleanup-stale-inbox.sh matches ai-toolbox source"
elif [[ -f "$CLEANUP_SRC" ]]; then
  fail "installed cleanup-stale-inbox.sh stale vs ai-toolbox source — run sync"
fi
bash -n "$CLEANUP" 2>/dev/null && ok "cleanup-stale-inbox.sh bash syntax valid" || fail "cleanup-stale-inbox.sh syntax error"

# ── temp control plane ──────────────────────────────────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cleanup-stub-test.XXXXXX")"
W="$TMP/work"
mkdir -p "$W/.orchestrate/logs" "$W/.orchestrate/tasks" "$W/.orchestrate/inbox/processed"

LIVE_ID=20260724-inbox-LIVE1
ORPHAN_ID=20260724-inbox-ORPH1
WORK_ID=20260724-inbox-WORK1

cat > "$W/.orchestrate/tasks/$LIVE_ID.md" <<EOF
# $LIVE_ID — parked by churn guard
source: self
mode: auto
bypassed_at: 2026-07-24T15:40:14Z
bypass_reason: churn — re-processed 3×
EOF

cat > "$W/.orchestrate/tasks/$ORPHAN_ID.md" <<EOF
# $ORPHAN_ID — parked by churn guard
source: self
mode: auto
bypassed_at: 2026-07-24T15:40:14Z
bypass_reason: churn — re-processed 3×
EOF

cat > "$W/.orchestrate/tasks/$WORK_ID.md" <<EOF
# $WORK_ID — a real in-progress task
mode: auto
### Phase 1
status: pending
EOF

cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — cleanup-stub-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $LIVE_ID | a stub still backed by a live row | auto | 1 | needs_human | 2026-01-01T00:00:00Z |
EOF

# Regex-metacharacter regression case (fix for unescaped $tid interpolation):
# tid contains a literal "." (an ERE metachar). The header text on disk
# differs from the tid by exactly the character under the metachar position
# ("X" instead of "."), so a literal string comparison must NOT treat this
# as a match. A pre-fix `grep -qE "^# ${tid} — parked by churn guard\$"`
# would let "." match "X" and incorrectly flag this as a stub match, since
# ERE dot matches any single character. No registry row exists for this ID,
# so if the buggy regex path were still active this file would be wrongly
# removed; the hardened literal-comparison path must preserve it.
META_ID="20260724-inbox-A.C1"
cat > "$W/.orchestrate/tasks/$META_ID.md" <<EOF
# 20260724-inbox-AXC1 — parked by churn guard
source: self
mode: auto
bypassed_at: 2026-07-24T15:40:14Z
bypass_reason: churn — re-processed 3×
EOF

bash "$CLEANUP" "$W" >/dev/null 2>&1

echo ""
echo "1. Stub with a live registry row is NOT removed"
[[ -f "$W/.orchestrate/tasks/$LIVE_ID.md" ]] && ok "live-row stub $LIVE_ID.md preserved" || fail "live-row stub $LIVE_ID.md was incorrectly removed"

echo ""
echo "2. Stub with NO registry row IS removed"
[[ ! -f "$W/.orchestrate/tasks/$ORPHAN_ID.md" ]] && ok "orphaned stub $ORPHAN_ID.md removed" || fail "orphaned stub $ORPHAN_ID.md was NOT removed"

echo ""
echo "3. Non-stub task file (has ### Phase, no registry row) is left untouched"
[[ -f "$W/.orchestrate/tasks/$WORK_ID.md" ]] && ok "non-stub work-in-progress file $WORK_ID.md preserved" || fail "non-stub file $WORK_ID.md was incorrectly removed"

echo ""
echo "4. Removal logged to heartbeat.log"
grep -q "removed orphaned churn-guard stub $ORPHAN_ID.md (no registry row)" "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null \
  && ok "heartbeat.log records orphaned stub removal" \
  || fail "heartbeat.log missing orphaned stub removal line"

echo ""
echo "5. tid regex metacharacter (.) does not cause a false-positive header match"
[[ -f "$W/.orchestrate/tasks/$META_ID.md" ]] \
  && ok "mismatched-header stub $META_ID.md preserved (literal comparison, not regex match)" \
  || fail "mismatched-header stub $META_ID.md was incorrectly removed (regex metachar false-positive)"

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED — see above" && exit 1
