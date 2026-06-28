#!/usr/bin/env bash
# churn-guard.sh — shared re-queue counter + "blocked after 3×" park mechanism.
#
# A poison task can loop forever: running → ghost-reset/needs_human → pending →
# running … with nothing detecting that the SAME task has been re-queued N times.
# This helper is the single owner of that counter, sourced by every requeue/
# re-dispatch site (run-job.sh, requeue-unblocked.sh, rescue.sh) so the logic and
# the storage exist exactly once.
#
# Counter storage (two layers, max() wins — survives the no-task-file case):
#   1. `requeue_count: N` line in `.orchestrate/tasks/<ID>.md` (when the file exists)
#   2. sidecar TSV `.orchestrate/logs/requeue-counts.tsv` keyed by ID
#      (ghost-reset auto jobs have NO task file — the sidecar is their only home)
#
# Threshold: on the 3rd re-processing the task is PARKED ("blocked") via the
# existing bypass mechanism — registry row left/forced to needs_human + the task
# file (created if absent) carries `bypassed_at:` + `bypass_reason: churn —
# re-processed 3×`, so tend-need-action.sh treats it as non-actionable and the
# launchd cycle stops waking the agent for it. An async investigation inbox job is
# auto-filed (source: self, mode: auto, triggered_by: <ID>), deduped.
#
# All registry writes keep the NF==8 invariant (exactly 6 cells with an EMPTY
# trailing $8). Every function is idempotent and safe to call repeatedly.
#
# Usage as a library:   source churn-guard.sh   (CG_ROOT must be set, or pass ROOT)
# Usage standalone (tests):   churn-guard.sh <fn> <ROOT> <ID> [args]

# Resolve ROOT: explicit CG_ROOT, else caller's ROOT, else cwd.
cg__root() { printf '%s' "${CG_ROOT:-${ROOT:-$(pwd)}}"; }

CG_THRESHOLD="${CG_THRESHOLD:-3}"

cg__sidecar() { printf '%s' "$(cg__root)/.orchestrate/logs/requeue-counts.tsv"; }
cg__taskfile() { printf '%s' "$(cg__root)/.orchestrate/tasks/${1}.md"; }
cg__heartbeat() { printf '%s' "$(cg__root)/.orchestrate/logs/heartbeat.log"; }

cg__sidecar_count() {
  local id="$1" sc
  sc="$(cg__sidecar)"
  [[ -f "$sc" ]] || { echo 0; return; }
  awk -F'\t' -v id="$id" '$1==id { print $2+0; found=1 } END { if (!found) print 0 }' "$sc" | tail -1
}

cg__taskfile_count() {
  local id="$1" tf n
  tf="$(cg__taskfile "$id")"
  [[ -f "$tf" ]] || { echo 0; return; }
  n="$(grep -E '^requeue_count:[[:space:]]*[0-9]+' "$tf" 2>/dev/null | head -1 | sed -E 's/^requeue_count:[[:space:]]*//')"
  echo "${n:-0}"
}

# cg_count <ID> — current re-queue count = max(task-file, sidecar).
cg_count() {
  local id="$1" a b
  a="$(cg__taskfile_count "$id")"
  b="$(cg__sidecar_count "$id")"
  if [[ "${a:-0}" -ge "${b:-0}" ]]; then echo "${a:-0}"; else echo "${b:-0}"; fi
}

cg__set_sidecar() {
  local id="$1" val="$2" sc tmp
  sc="$(cg__sidecar)"
  mkdir -p "$(dirname "$sc")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/cg-sidecar.XXXXXX")"
  if [[ -f "$sc" ]]; then
    awk -F'\t' -v id="$id" '$1!=id { print }' "$sc" > "$tmp" 2>/dev/null || true
  fi
  printf '%s\t%s\n' "$id" "$val" >> "$tmp"
  mv "$tmp" "$sc"
}

cg__set_taskfile() {
  local id="$1" val="$2" tf tmp
  tf="$(cg__taskfile "$id")"
  [[ -f "$tf" ]] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/cg-tf.XXXXXX")"
  if grep -qE '^requeue_count:' "$tf" 2>/dev/null; then
    sed -E "s/^requeue_count:.*/requeue_count: ${val}/" "$tf" > "$tmp" && mv "$tmp" "$tf"
  else
    # Insert after the first line (title) so it lands in the header region.
    awk -v v="$val" 'NR==1 { print; print "requeue_count: " v; next } { print }' "$tf" > "$tmp" && mv "$tmp" "$tf"
  fi
}

# cg_increment <ID> — bump the counter in BOTH layers; echo the new count.
cg_increment() {
  local id="$1" cur new
  cur="$(cg_count "$id")"
  new=$(( cur + 1 ))
  cg__set_sidecar "$id" "$new"
  cg__set_taskfile "$id" "$new"   # no-op if task file absent
  echo "$new"
}

# cg_reset <ID> — zero the counter on completion (remove sidecar row + zero file line).
cg_reset() {
  local id="$1" sc tmp tf tftmp
  sc="$(cg__sidecar)"
  if [[ -f "$sc" ]]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/cg-sidecar.XXXXXX")"
    awk -F'\t' -v id="$id" '$1!=id { print }' "$sc" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$sc"
  fi
  tf="$(cg__taskfile "$id")"
  if [[ -f "$tf" ]] && grep -qE '^requeue_count:' "$tf" 2>/dev/null; then
    tftmp="$(mktemp "${TMPDIR:-/tmp}/cg-tf.XXXXXX")"
    grep -vE '^requeue_count:' "$tf" > "$tftmp" && mv "$tftmp" "$tf"
  fi
}

# cg__park_registry <ID> — force the registry row to needs_human (NF==8-safe).
# No-op when the row is already needs_human. Atomic temp+mv.
cg__park_registry() {
  local id="$1" proj tmp now
  proj="$(cg__root)/.orchestrate/project.md"
  [[ -f "$proj" ]] || return 0
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  awk -F'|' -v OFS='|' -v id="$id" -v now="$now" '
    /^\|[[:space:]]*[0-9A-Za-z]/ && NF>=8 {
      rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
      st=$6;  gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
      if (rid==id && st!="complete") {
        $6=" needs_human "; $7=" " now " "
        if (NF>8) { NF=8; $8="" }   # self-heal phantom columns, restore trailing pipe
      }
    }
    { print }
  ' "$proj" > "$tmp" && mv "$tmp" "$proj"
}

# cg__write_bypass <ID> — ensure the task file carries bypassed_at: + bypass_reason:
# so tend-need-action.sh treats the row as parked/non-actionable. Creates a minimal
# task file when the row is a no-task-file ghost (so the bypass marker has a home).
cg__write_bypass() {
  local id="$1" reason="$2" tf now
  tf="$(cg__taskfile "$id")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$tf")"
  if [[ ! -f "$tf" ]]; then
    {
      printf '# %s — parked by churn guard\n' "$id"
      printf 'source: self\nmode: auto\n'
      printf 'bypassed_at: %s\n' "$now"
      printf 'bypass_reason: %s\n' "$reason"
    } > "$tf"
    return 0
  fi
  # Existing file: refresh/insert the markers idempotently.
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/cg-bypass.XXXXXX")"
  grep -vE '^(bypassed_at|bypass_reason):' "$tf" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$tf"
  awk -v at="$now" -v rs="$reason" '
    NR==1 { print; print "bypassed_at: " at; print "bypass_reason: " rs; next }
    { print }
  ' "$tf" > "${tf}.cgtmp" && mv "${tf}.cgtmp" "$tf"
}

# cg_file_investigation <ID> — write an async investigation inbox job, deduped on
# `triggered_by: <ID>` across inbox/ + processed/. Echoes the path written, or
# nothing when deduped.
cg_file_investigation() {
  local id="$1" root inbox iso dest f
  root="$(cg__root)"
  inbox="$root/.orchestrate/inbox"
  mkdir -p "$inbox" "$inbox/processed" 2>/dev/null || true
  # Dedup: skip if any inbox file (active or processed) already targets this ID.
  for f in "$inbox"/*.md "$inbox"/processed/*.md; do
    [[ -f "$f" ]] || continue
    if grep -qE "^triggered_by:[[:space:]]*${id}\b" "$f" 2>/dev/null; then
      return 0   # already filed
    fi
  done
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  dest="$inbox/investigate-churn-${id}-${iso}.md"
  # Pull the registry row + any churn-guard heartbeat lines for Context.
  local proj row hb_lines
  proj="$root/.orchestrate/project.md"
  row="$(grep -E "^\|[[:space:]]*${id}[[:space:]]*\|" "$proj" 2>/dev/null | head -1 || true)"
  hb_lines="$(grep -E "(ghost-reset|requeue|churn).*${id}" "$(cg__heartbeat)" 2>/dev/null | tail -10 || true)"
  {
    printf 'source: self\n'
    printf 'mode: auto\n'
    printf 'triggered_by: %s\n\n' "$id"
    printf '# Investigate churn — %s re-processed %s×\n\n' "$id" "$CG_THRESHOLD"
    printf '## Goal\n'
    printf 'Root-cause why `%s` was re-processed %s× without converging, and propose/apply a fix.\n\n' "$id" "$CG_THRESHOLD"
    printf '## Context\n'
    printf 'The churn guard parked `%s` (needs_human + bypass_reason: churn — re-processed %s×) after it cycled running → needs_human/ghost-reset → pending → running repeatedly without completing.\n\n' "$id" "$CG_THRESHOLD"
    printf 'Registry row at park time:\n```\n%s\n```\n\n' "${row:-<row not found>}"
    printf 'Relevant heartbeat lines:\n```\n%s\n```\n\n' "${hb_lines:-<none>}"
    printf '## Acceptance Criteria\n'
    printf '%s\n' '- Identify the convergence failure (poison input, missing dependency, non-idempotent step, or detection bug).'
    printf '%s\n' '- Propose and, where safe, apply a fix so the task can complete or be correctly closed.'
    printf '%s\n' "- Clear the bypass on \`${id}\` (or document why it must stay parked)."
  } > "$dest"
  echo "$dest"
}

# cg_park_if_churned <ID> [reason] — if the counter has reached CG_THRESHOLD, park
# the task (registry needs_human + bypass markers), file the investigation job
# (deduped), and append a churn-guard heartbeat line. Returns 0 when it parked
# (caller should stop re-queueing), 1 when below threshold (caller proceeds).
# Idempotent: a second call after parking re-detects threshold, re-parks no-op,
# and does NOT double-file (investigation dedup on triggered_by).
cg_park_if_churned() {
  local id="$1"
  local count
  count="$(cg_count "$id")"
  if [[ "${count:-0}" -lt "$CG_THRESHOLD" ]]; then
    return 1
  fi
  local reason="churn — re-processed ${CG_THRESHOLD}×"
  cg__park_registry "$id"
  cg__write_bypass "$id" "$reason"
  local filed
  filed="$(cg_file_investigation "$id")"
  local hb iso
  hb="$(cg__heartbeat)"
  mkdir -p "$(dirname "$hb")"
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local invname="investigate-churn-${id}"
  echo "[${iso}] churn-guard — blocked ${id} after ${CG_THRESHOLD} re-processings; filed ${invname}" >> "$hb"
  return 0
}

# Standalone dispatch for tests / scripting.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  fn="${1:?usage: churn-guard.sh <cg_increment|cg_count|cg_reset|cg_park_if_churned|cg_file_investigation> <ROOT> <ID> [args]}"
  CG_ROOT="${2:?ROOT required}"
  shift 2
  "$fn" "$@"
fi
