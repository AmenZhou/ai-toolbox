#!/usr/bin/env bash
# finalize-completed-tasks.sh — auto-finalize watchdog (Completion is not atomic).
#
# Reconciles registry rows stuck at `running` (or `needs_human`) whose work is
# actually DONE, by running the bash analog of the SKILL Completion sequence:
# flip the row to `complete`, ensure it is archived to orchestrate-history/ +
# MANIFEST, and delete the stale .orchestrate/tasks/{ID}.md.
#
# A tend/agent session can die mid-Completion: it may have written every phase
# block to ✓ complete in the task file (and possibly archived it) but crashed
# before flipping the registry row from running→complete. T-4 only re-queues
# `needs_human` rows, so such a row sits `running` forever. This helper closes
# that gap from pure bash — no agent, no tokens.
#
# Reconcile rule — for each registry data row whose status is `running` or
# `needs_human`, finalize to `complete` when EITHER:
#   (1) its .orchestrate/tasks/{ID}.md exists AND every phase block is
#       `status: ✓ complete` AND the count of ✓ complete phase blocks equals the
#       file's `total_phases:` (conservative — never finalize partial work); OR
#   (2) an archive file matching the ID already exists in orchestrate-history/
#       (the "died mid-Completion after archiving" case).
#
# On finalize: set row status=complete + last_activity=<now> IN PLACE preserving
# NF==8; if no archive exists, archive the task file to
# orchestrate-history/{STAMP}-{ID}-{slug}.md + append a MANIFEST line; if an
# archive already exists do NOT duplicate; delete the stale task file; append an
# auto-finalize line to heartbeat.log. Idempotent: a second run is a clean no-op.
#
# Wired into run-job.sh tend preflight (primary; after repair_registry_rows,
# before reset_stale_running_tasks) and rescue.sh (safety net).
set -euo pipefail

ROOT="${1:-$(pwd)}"
PROJ="$ROOT/.orchestrate/project.md"
TASKS_DIR="$ROOT/.orchestrate/tasks"
HISTORY_DIR="$ROOT/orchestrate-history"
MANIFEST="$HISTORY_DIR/MANIFEST.md"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"

[[ -f "$PROJ" ]] || exit 0

log_fin() {
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
  mkdir -p "$(dirname "$HEARTBEAT")" 2>/dev/null || true
  echo "$line" >> "$HEARTBEAT" 2>/dev/null || true
}

# Find an existing archive file for an ID (returns first match path, or empty).
# Archive naming is {STAMP}-{ID}-{slug}.md, so anchor on -{ID}- after the stamp.
find_archive_for_id() {
  local id="$1"
  [[ -d "$HISTORY_DIR" ]] || return 0
  local f
  for f in "$HISTORY_DIR"/*-"${id}"-*.md; do
    [[ -f "$f" ]] || continue
    printf '%s\n' "$f"
    return 0
  done
  return 0
}

# Decide whether a task file represents fully-completed work (all phases ✓).
# Conservative: requires total_phases: to be present AND the number of
# `status: ✓ complete` phase-block lines to equal it.
task_file_all_phases_complete() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local total complete
  total="$(grep -E '^total_phases:' "$file" 2>/dev/null | head -1 | sed -E 's/^total_phases:[[:space:]]*//' | tr -dc '0-9')"
  [[ -n "$total" && "$total" -gt 0 ]] || return 1
  # grep -c prints its count to stdout AND exits 1 when the count is 0; the
  # `|| echo 0` would then append a SECOND "0" → a multiline value that breaks
  # the arithmetic test. Sanitize to the first run of digits instead.
  complete="$(grep -cE '^status:[[:space:]]*✓ complete' "$file" 2>/dev/null | head -1 | tr -dc '0-9')"
  [[ -n "$complete" ]] || complete=0
  [[ "$complete" -eq "$total" ]]
}

# Derive a filesystem-safe slug for the archive filename from the task title.
derive_slug() {
  local file="$1" id="$2"
  local slug=""
  if [[ -f "$file" ]]; then
    slug="$(grep -m1 -E '^# Task:' "$file" 2>/dev/null | sed -E 's/^# Task:[[:space:]]*//')"
  fi
  # Lowercase, strip non-alnum to hyphens, collapse, trim.
  slug="$(printf '%s' "$slug" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-60)"
  [[ -n "$slug" ]] && printf '%s\n' "$slug" || printf '%s\n' "auto-finalized"
}

# Flip a single registry row ID running|needs_human → complete, in place,
# preserving NF==8 (and self-healing any phantom column). Atomic temp+mv.
# Returns 0 only if a row was actually flipped.
finalize_registry_row() {
  local id="$1"
  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  awk -F'|' -v OFS='|' -v id="$id" -v ts="$now_iso" '
    /^\|[[:space:]]*[0-9]/ && NF>=8 {
      rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
      st=$6;  gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
      if (rid==id && (st=="running" || st=="needs_human")) {
        $6=" complete "; $7=" " ts " "
        if (NF>8) { NF=8; $8="" }
        flipped=1
      }
    }
    { print }
    END { exit (flipped ? 0 : 2) }
  ' "$PROJ" > "$tmp" || rc=$?
  if [[ $rc -eq 0 ]]; then
    mv "$tmp" "$PROJ"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Archive a task file to orchestrate-history/ + append MANIFEST line, ONLY if no
# archive for the ID already exists. Adds a `tags:` line if absent. Returns the
# archive basename on stdout when it creates one (empty if it reused an existing).
archive_task_file() {
  local id="$1" file="$2"
  local existing
  existing="$(find_archive_for_id "$id")"
  if [[ -n "$existing" ]]; then
    return 0  # already archived — never duplicate
  fi
  [[ -f "$file" ]] || return 0  # nothing to archive (rule-2 with no task file)
  mkdir -p "$HISTORY_DIR"
  local stamp slug base dest
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  slug="$(derive_slug "$file" "$id")"
  base="${stamp}-${id}-${slug}.md"
  dest="$HISTORY_DIR/$base"
  {
    if ! grep -qE '^tags:' "$file" 2>/dev/null; then
      echo "tags: orchestrate, watchdog, completion, auto-finalize"
    fi
    cat "$file"
  } > "$dest"
  # Append MANIFEST line (create header-less append; MANIFEST already exists).
  local summary
  summary="$(grep -m1 -E '^# Task:' "$file" 2>/dev/null | sed -E 's/^# Task:[[:space:]]*//')"
  [[ -n "$summary" ]] || summary="auto-finalized task $id"
  printf '%s | %s | %s | orchestrate, watchdog, auto-finalize\n' \
    "$(date -u +%Y-%m-%d)" "$base" "$summary" >> "$MANIFEST"
  printf '%s\n' "$base"
}

finalize_completed_tasks() {
  [[ -f "$PROJ" ]] || return 0
  # Read candidate rows (running or needs_human) positionally — NF-tolerant.
  local row_id status
  while IFS='|' read -r _ row_id _ _ _ status _ _; do
    row_id="${row_id// /}"
    status="${status// /}"
    [[ -z "$row_id" || "$row_id" == "ID" || "$row_id" =~ ^-+$ ]] && continue
    [[ "$status" == "running" || "$status" == "needs_human" ]] || continue

    local task_file="$TASKS_DIR/${row_id}.md"
    local archive
    archive="$(find_archive_for_id "$row_id")"

    local should_finalize=0
    if [[ -n "$archive" ]]; then
      should_finalize=1                          # rule (2): already archived
    elif task_file_all_phases_complete "$task_file"; then
      should_finalize=1                          # rule (1): all phases ✓
    fi
    [[ "$should_finalize" -eq 1 ]] || continue

    # Flip the registry row first (the durable signal). If it does not flip
    # (malformed/raced row), skip the rest so we never half-finalize.
    if ! finalize_registry_row "$row_id"; then
      log_fin "auto-finalize SKIPPED $row_id: row did not flip (malformed/raced); awaiting repair_registry_rows"
      continue
    fi

    # Archive if not already archived (never duplicates).
    local created
    created="$(archive_task_file "$row_id" "$task_file")"

    # Delete the stale task file (idempotent — -f).
    rm -f "$task_file"

    if [[ -n "$created" ]]; then
      log_fin "auto-finalize — completed $row_id (all phases ✓; registry was running) → archived $created"
    else
      log_fin "auto-finalize — completed $row_id (registry was $status; archive already existed) → reconciled"
    fi
  done < <(grep -E '^\|[[:space:]]*[0-9]' "$PROJ" 2>/dev/null || true)
}

finalize_completed_tasks
