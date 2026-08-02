#!/usr/bin/env bash
# check-depends-on.sh — standalone cross-task depends_on: gate for single-ID
# dispatch paths that never go through run-job.sh's mark_pending_tasks_as_running()
# batch pre-dispatch gate (RS01 / CROSS-2, 20260727-inbox-7D4A).
#
# Gap this closes (DEP-TEND-IMPL, reports/orchestrate/dep-tend-inv_plan.md §2):
# `tend go auto <ID>` and the human/dashboard `go`/`go auto` approval of an
# `awaiting_go` row both skip T-4 entirely, so a task whose depends_on: names
# an incomplete sibling task could previously be force-dispatched with no
# depends_on: check anywhere (bash or LLM-prose). This script wraps the exact
# same logic as run-job.sh's cross_task_depends_on_blocked() so it is directly
# invokable for a single ID without a bulk registry scan.
#
# Usage: check-depends-on.sh <ROOT> <ID>
#   ROOT — project root (contains .orchestrate/project.md and .orchestrate/tasks/)
#   ID   — registry task ID (e.g. 20260801-inbox-17BD)
#
# Exit 0 (BLOCKED): depends_on: names another registry task not yet complete.
#   Prints "<dep_id>\t<dep_status>" to stdout — same contract as the
#   in-process cross_task_depends_on_blocked() function in run-job.sh.
# Exit 1 (CLEAR): no cross-task block — safe to dispatch. Covers: missing
#   task file, no depends_on: line, depends_on: none, a same-file phase
#   number (not a registry-ID shape), or a depends_on: target whose
#   registry status is already complete.
set -uo pipefail

ROOT="${1:?usage: check-depends-on.sh <ROOT> <ID>}"
ID="${2:?usage: check-depends-on.sh <ROOT> <ID>}"

PROJ="$ROOT/.orchestrate/project.md"
TASKS_DIR="$ROOT/.orchestrate/tasks"

# --- inlined from run-job.sh's cross_task_depends_on_blocked() (CROSS-2) ---
# Keep this function body byte-for-byte in sync with run-job.sh's copy.
cross_task_depends_on_blocked() {
  local id="$1" proj="$2" tasks_dir="$3"
  local tf="$tasks_dir/${id}.md"
  [[ -f "$tf" ]] || return 1
  local dep
  dep="$(grep -m1 -E '^depends_on:[[:space:]]*\S' "$tf" 2>/dev/null \
    | sed -E 's/^depends_on:[[:space:]]*//')"
  [[ -z "$dep" || "$dep" == "none" ]] && return 1
  [[ "$dep" =~ ^[0-9]{8}-inbox-[0-9A-Fa-f]{4}$ ]] || return 1
  local dep_status
  dep_status="$(awk -F'|' -v dep="$dep" '
    $0 ~ ("\\| " dep " \\|") {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6); print $6; exit
    }
  ' "$proj" 2>/dev/null)"
  [[ "$dep_status" == "complete" ]] && return 1
  printf '%s\t%s\n' "$dep" "${dep_status:-unknown}"
  return 0
}
# --- end inlined block ---

block_info="$(cross_task_depends_on_blocked "$ID" "$PROJ" "$TASKS_DIR" || true)"
if [[ -n "$block_info" ]]; then
  printf '%s\n' "$block_info"
  exit 0
fi
exit 1
