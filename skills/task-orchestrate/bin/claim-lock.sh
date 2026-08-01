#!/usr/bin/env bash
# claim-lock.sh — short per-ID claim lock preventing two runners from
# independently claiming/re-executing the same registry row.
#
# Root cause this closes (20260801-inbox-D198/668C, see project.md Shared
# Context "cursor fallback dispatch raced this session's redispatch of the
# same orphan-requeued row"): a `claude` primary session's wrapper (run-job.sh)
# fell back to `cursor` after a timeout; requeue-orphaned-running.sh's
# dead-session-pid heuristic then saw the TIMED-OUT SUB-PROCESS's death line
# and concluded the row was orphaned, resetting it to `pending` WHILE the
# `cursor` fallback (dispatched by the SAME still-alive wrapper) was still
# actively working it. A separate, later tend cycle then claimed the
# newly-`pending` row too, and both sessions independently finished it — one
# writing a raw out-of-domain `status: cancelled` plus an unescaped 7th
# `|`-field that update-registry-row.sh correctly refused to touch.
#
# The dead-session-pid heuristic tracks the SUB-PROCESS pid (the actual
# claude/cursor CLI invocation), which can legitimately die (timeout kill)
# while the WRAPPER (run-job.sh's own $$, which owns the whole
# primary-then-fallback sequence) is still alive and about to retry. This
# lock is keyed to the WRAPPER's pid instead, giving requeue-orphaned-running.sh
# a strictly more reliable liveness signal to check before it un-claims a row.
#
# Lock shape: .orchestrate/locks/<ID>.claim/  (a directory — mkdir is atomic
# on every POSIX filesystem, no flock(1) dependency needed; mirrors the C319
# decision already made for run-job.sh's own .tend.lock). Contents: a single
# `owner` file holding "<pid> <iso-acquired>".
#
# CLAIM_LOCK_ROOT (or ROOT) must be set before sourcing/calling into this
# library, or pass ROOT explicitly to the standalone dispatcher below.
#
# Usage as a library (source into a caller's own `set -e` script — this file
# deliberately does NOT set -e itself, since a failed `mkdir`/`kill -0` probe
# inside these functions is an expected, handled outcome, not a fatal error):
#   source claim-lock.sh
#   claim_lock_acquire <ID>   — 0 = acquired (or reclaimed a stale lock), 1 = held by a live owner
#   claim_lock_release <ID>   — remove the lock dir IF owned by this process ($$); no-op otherwise
#   claim_lock_is_live <ID>   — 0 if a lock dir exists, is within CLAIM_LOCK_TTL_SECS, and its
#                                recorded owner pid is alive; 1 otherwise (absent/stale/dead)
#
# Usage standalone (tests / scripting):
#   claim-lock.sh <acquire|release|is_live> <ROOT> <ID>

# CLAIM_LOCK_TTL_SECS: must comfortably exceed the longest a single wrapper
# invocation can legitimately hold a claim — primary AND fallback each bounded
# by AGENT_TIMEOUT_SECS (default 1200s in run-job.sh) plus overhead, so the
# default here (2700s = 45min) covers 2x1200s + margin without relying on any
# one AGENT_TIMEOUT_SECS override.
CLAIM_LOCK_TTL_SECS="${CLAIM_LOCK_TTL_SECS:-2700}"

claim_lock__root() { printf '%s' "${CLAIM_LOCK_ROOT:-${ROOT:-$(pwd)}}"; }
claim_lock__dir() { printf '%s' "$(claim_lock__root)/.orchestrate/locks/${1}.claim"; }

# claim_lock_is_live <ID> — 0 (true) when a lock dir exists for <ID>, has not
# exceeded CLAIM_LOCK_TTL_SECS, and its recorded owner pid responds to
# `kill -0` (still alive). Anything else (no lock, stale by TTL, dead owner)
# is 1 (false/not live) — a caller may safely proceed as if unclaimed.
claim_lock_is_live() {
  local id="$1" dir owner_file owner_pid age mtime now
  dir="$(claim_lock__dir "$id")"
  [[ -d "$dir" ]] || return 1
  owner_file="$dir/owner"
  owner_pid="$(awk 'NR==1{print $1}' "$owner_file" 2>/dev/null)"
  mtime="$(date -r "$dir" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age=$(( now - mtime ))
  if [[ "$age" -ge "$CLAIM_LOCK_TTL_SECS" ]]; then
    return 1   # stale by TTL — never treated as live, regardless of pid state
  fi
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$owner_pid" 2>/dev/null
}

# claim_lock_acquire <ID> — atomically claim the lock for this process ($$).
# Reclaims a lock that is present but NOT live (dead owner or past TTL) before
# retrying, so a crashed wrapper never permanently wedges an ID. Returns 0 on
# success (fresh acquire or reclaim), 1 if a live owner already holds it.
claim_lock_acquire() {
  local id="$1" dir
  dir="$(claim_lock__dir "$id")"
  mkdir -p "$(dirname "$dir")" 2>/dev/null || true
  if mkdir "$dir" 2>/dev/null; then
    printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/owner" 2>/dev/null || true
    return 0
  fi
  if claim_lock_is_live "$id"; then
    return 1
  fi
  # Present but not live — reclaim. Best-effort race: if a concurrent
  # reclaimer wins the re-create, we simply fail this attempt (caller retries
  # next cycle) rather than risk clobbering a fresh legitimate owner.
  rm -rf "$dir" 2>/dev/null || true
  if mkdir "$dir" 2>/dev/null; then
    printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/owner" 2>/dev/null || true
    return 0
  fi
  return 1
}

# claim_lock_release <ID> — remove the lock dir ONLY if owned by this process
# ($$). A no-op (never removes another owner's live claim) when the recorded
# owner pid does not match — protects against a slow/late release call from a
# process whose lock has already been reclaimed by someone else.
claim_lock_release() {
  local id="$1" dir owner_pid
  dir="$(claim_lock__dir "$id")"
  [[ -d "$dir" ]] || return 0
  owner_pid="$(awk 'NR==1{print $1}' "$dir/owner" 2>/dev/null)"
  [[ "$owner_pid" == "$$" ]] || return 0
  rm -rf "$dir" 2>/dev/null || true
}

# Standalone dispatch for tests / scripting.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  fn="${1:?usage: claim-lock.sh <acquire|release|is_live> <ROOT> <ID>}"
  CLAIM_LOCK_ROOT="${2:?ROOT required}"
  id="${3:?ID required}"
  "claim_lock_${fn}" "$id"
fi
