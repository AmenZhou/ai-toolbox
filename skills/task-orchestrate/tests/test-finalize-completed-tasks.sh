#!/usr/bin/env bash
# test-finalize-completed-tasks.sh — regression for task 20260627-inbox-E721.
#
# Background: Completion is NOT atomic. A tend/agent session can write every phase
# block in a task file to ✓ complete (and maybe archive it) but die before
# flipping the registry row running→complete. T-4 re-queues only `needs_human`
# rows, so the done-but-running row sits `running` forever. finalize-completed-
# tasks.sh runs the bash analog of the SKILL Completion sequence to reap them.
#
# Asserts the reconcile rule:
#   (a) running row + all-phases-✓ task file → complete + archived + task deleted
#   (b) running row with partial (not-all-✓) task file → left running, untouched
#   (c) running row whose ID already has an archive but no task file → flipped to
#       complete with NO dup archive / NO dup MANIFEST line
#   (d) second run is a clean no-op (idempotent)
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="${HELPER:-$PROJECT_ROOT/.orchestrate/bin/finalize-completed-tasks.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

OLD_TS="2026-06-28T01:00:00Z"

# status_of <project.md> <id> → trimmed status field ($6)
status_of() {
  awk -F'|' -v id="$2" '
    /^\|[[:space:]]*[0-9]/ {
      rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
      if (rid==id) { st=$6; gsub(/^[[:space:]]+|[[:space:]]+$/,"",st); print st; exit }
    }' "$1"
}

# count_archives <history-dir> <id> → number of archive files for id
count_archives() {
  ls "$1"/*-"$2"-*.md 2>/dev/null | wc -l | tr -d ' '
}

# Build a fresh mock control plane covering all four scenarios; echo its path.
build_cp() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/.orchestrate/tasks" "$T/.orchestrate/logs" "$T/orchestrate-history"
  {
    echo "# Project"
    echo "## Task Registry"
    echo "| ID | Summary | Mode | Phase | Status | Last Activity |"
    echo "|----|---------|------|-------|--------|---------------|"
    echo "| 20260628-aaa1 | scenario a all complete | auto | 2 | running | $OLD_TS |"
    echo "| 20260628-bbb2 | scenario b partial | auto | 2 | running | $OLD_TS |"
    echo "| 20260628-ccc3 | scenario c archive exists | auto | 1 | running | $OLD_TS |"
    echo "| 20260628-ddd4 | scenario d genuinely running | auto | 1 | running | $OLD_TS |"
  } > "$T/.orchestrate/project.md"

  # (a) all phases ✓ (2/2)
  printf '%s\n' \
    "# Task: Scenario A all complete" "id: 20260628-aaa1" "total_phases: 2" \
    "### Phase 1" "status: ✓ complete" "### Phase 2" "status: ✓ complete" \
    > "$T/.orchestrate/tasks/20260628-aaa1.md"

  # (b) partial (1/2 ✓)
  printf '%s\n' \
    "# Task: Scenario B partial" "id: 20260628-bbb2" "total_phases: 2" \
    "### Phase 1" "status: ✓ complete" "### Phase 2" "status: ⏳ pending" \
    > "$T/.orchestrate/tasks/20260628-bbb2.md"

  # (c) archive already exists, NO task file
  printf '%s\n' "# Task: Scenario C already archived" "id: 20260628-ccc3" \
    > "$T/orchestrate-history/20260628-000000-20260628-ccc3-already-archived.md"

  # (d) genuinely running: task file present but ZERO ✓ phases, no archive
  printf '%s\n' \
    "# Task: Scenario D genuinely running" "id: 20260628-ddd4" "total_phases: 2" \
    "### Phase 1" "status: ⏳ in_progress" "### Phase 2" "status: ⏳ pending" \
    > "$T/.orchestrate/tasks/20260628-ddd4.md"

  printf '%s\n' "# Orchestration History Manifest" > "$T/orchestrate-history/MANIFEST.md"
  printf '%s' "$T"
}

echo "── finalize-completed-tasks: reconcile rule (a–d) + idempotency ──"

[[ -x "$HELPER" ]] && ok "helper is executable" || fail "helper not executable: $HELPER"

CP="$(build_cp)"
bash "$HELPER" "$CP" >/dev/null 2>&1

# (a) → complete, archived, task file deleted
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-aaa1)" == "complete" ]] \
  && ok "(a) all-✓ row → complete" || fail "(a) all-✓ row not complete"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-aaa1)" -eq 1 ]] \
  && ok "(a) all-✓ row archived once" || fail "(a) all-✓ row not archived exactly once"
[[ ! -f "$CP/.orchestrate/tasks/20260628-aaa1.md" ]] \
  && ok "(a) stale task file deleted" || fail "(a) task file not deleted"
grep -q '20260628-aaa1' "$CP/orchestrate-history/MANIFEST.md" \
  && ok "(a) MANIFEST line appended" || fail "(a) no MANIFEST line"

# (b) → left running, untouched
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-bbb2)" == "running" ]] \
  && ok "(b) partial row left running" || fail "(b) partial row was finalized (BAD)"
[[ -f "$CP/.orchestrate/tasks/20260628-bbb2.md" ]] \
  && ok "(b) partial task file untouched" || fail "(b) partial task file deleted (BAD)"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-bbb2)" -eq 0 ]] \
  && ok "(b) partial row not archived" || fail "(b) partial row archived (BAD)"

# (c) → complete, NO dup archive (still exactly 1), NO dup MANIFEST line
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-ccc3)" == "complete" ]] \
  && ok "(c) archive-exists row → complete" || fail "(c) archive-exists row not complete"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-ccc3)" -eq 1 ]] \
  && ok "(c) no dup archive (still 1)" || fail "(c) duplicate archive created (BAD)"
[[ "$(grep -c '20260628-ccc3' "$CP/orchestrate-history/MANIFEST.md")" -eq 0 ]] \
  && ok "(c) no MANIFEST line for pre-archived row" || fail "(c) spurious MANIFEST line (BAD)"

# (d) → left running
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-ddd4)" == "running" ]] \
  && ok "(d) genuinely-running row untouched" || fail "(d) genuinely-running row finalized (BAD)"

# Invariant: every data row stays NF==8 with empty trailing field
BAD="$(awk -F'|' '/^\|[[:space:]]*2026/ { t=$8; gsub(/[[:space:]]/,"",t); if (NF!=8 || t!="") c++ } END{print c+0}' "$CP/.orchestrate/project.md")"
[[ "$BAD" -eq 0 ]] && ok "registry invariant preserved (NF==8)" || fail "registry invariant broken ($BAD bad rows)"

# (d-idempotency) second run = clean no-op
REG_SNAP="$(mktemp)"; cp "$CP/.orchestrate/project.md" "$REG_SNAP"
HIST_BEFORE="$(ls "$CP/orchestrate-history"/*.md 2>/dev/null | wc -l | tr -d ' ')"
MAN_BEFORE="$(grep -c '^2026' "$CP/orchestrate-history/MANIFEST.md" || true)"
bash "$HELPER" "$CP" >/dev/null 2>&1
diff -q "$REG_SNAP" "$CP/.orchestrate/project.md" >/dev/null \
  && ok "(d) 2nd run: registry unchanged (idempotent)" || fail "(d) 2nd run mutated registry (BAD)"
HIST_AFTER="$(ls "$CP/orchestrate-history"/*.md 2>/dev/null | wc -l | tr -d ' ')"
MAN_AFTER="$(grep -c '^2026' "$CP/orchestrate-history/MANIFEST.md" || true)"
[[ "$HIST_BEFORE" -eq "$HIST_AFTER" ]] \
  && ok "(d) 2nd run: no new archive" || fail "(d) 2nd run created archive (BAD)"
[[ "$MAN_BEFORE" -eq "$MAN_AFTER" ]] \
  && ok "(d) 2nd run: no new MANIFEST line" || fail "(d) 2nd run appended MANIFEST (BAD)"

rm -rf "$CP" "$REG_SNAP"

echo ""
echo "  finalize-completed-tasks: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
