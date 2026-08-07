#!/usr/bin/env bash
# enqueue-review-and-tests.sh — auto-enqueue a review + a tests follow-up ticket
# for a completed code-changing task (R-1 / OR-1).
#
# When a task that changed code completes, task-orchestrate must guarantee an
# INDEPENDENT review pass and test pass against the change. This helper writes
# exactly two inbox tickets into the canonical ai-console inbox — one
# `kind: review`, one `kind: tests` — so a FRESH tend cycle runs those passes
# (the inline critic/Test&Verify gate runs in the authoring session and is kept;
# this supplements it — R-1 Decision 3).
#
# Contract (R-1 Decisions 2/4/5/7):
#   - Trigger: fires only when the source task's aggregate `files_changed:` has at
#     least one CODE file (see is_code_change) — pure docs/log/registry tasks
#     enqueue NOTHING and the script exits non-zero.
#   - Anti-recursion: if the SOURCE task itself carries a `followup_for:` header
#     (it IS a review/tests ticket), enqueue NOTHING (exit 0) — terminal.
#   - Dedup/idempotent: before writing EITHER ticket, skip it if a ticket with the
#     same (followup_for, kind) pair already exists in inbox/ (active+gated+
#     processed), the registry's task files, or orchestrate-history/.
#   - Gating reality: generated tickets land `auto` — NO `gate_reason:` line and NO
#     risky-op literals in the body, so drain-inbox keeps them `pending`.
#
# Usage:
#   ENQ_ROOT=<project-root> enqueue-review-and-tests.sh <source-task-ID>
#     reads files_changed/followup_for/title from $ENQ_ROOT/.orchestrate/tasks/<ID>.md
#   ENQ_FILES="a.ts b.md" enqueue-review-and-tests.sh <ID>
#     overrides the files list (for tests / when the task file is gone)
#   ENQ_FOLLOWUP_FOR=1 ...   forces the anti-recursion skip (for tests)
#
# ENQ_ROOT defaults to the current working directory. Generated tickets ALWAYS go
# to the canonical ai-console inbox unless ENQ_INBOX_ROOT overrides it (tests set
# ENQ_INBOX_ROOT=$ENQ_ROOT so writes land in the temp control plane).
set -euo pipefail

ID="${1:-}"
if [[ -z "$ID" ]]; then
  echo "enqueue-review-and-tests.sh: missing <source-task-ID>" >&2
  exit 2
fi

# ID is interpolated directly into TASK_FILE / archive-glob / dest ticket-name
# path construction below. No call site today passes anything but an
# internally-generated YYYYMMDD-... ID, but validate the charset defensively
# before it ever reaches path construction — otherwise a less-trusted ID
# source (e.g. "../../etc/passwd") would be a path-traversal vector
# (20260724-inbox-6D91).
if [[ ! "$ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "enqueue-review-and-tests.sh: invalid ID '$ID' — must match ^[A-Za-z0-9_-]+\$" >&2
  exit 2
fi

ROOT="${ENQ_ROOT:-$(pwd)}"
TASK_FILE="$ROOT/.orchestrate/tasks/${ID}.md"

# Canonical ai-console inbox is the only live drop-zone; tests redirect via
# ENQ_INBOX_ROOT so they never touch the real inbox.
INBOX_ROOT="${ENQ_INBOX_ROOT:-/Users/haimengzhou/apps/ai-console}"
INBOX="$INBOX_ROOT/.orchestrate/inbox"
GATED="$INBOX/gated"
PROCESSED="$INBOX/processed"
PROJ="$ROOT/.orchestrate/project.md"
TASKS_DIR="$ROOT/.orchestrate/tasks"
HISTORY_DIR="$ROOT/orchestrate-history"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"

# Archive fallback: the model-path Completion sequence deletes the live task file
# (step 1) BEFORE this 6b enqueue runs (step 6b), so without this a genuine
# code-changing task reads an absent file, finds no `files_changed`, and is wrongly
# skipped as "no code change". When the live file is gone, resolve TASK_FILE to the
# newest archived copy `orchestrate-history/*-{ID}-*.md` (ID is dash-bounded in the
# archive name: {STAMP}-{ID}-{slug}.md). Applied here so BOTH the anti-recursion
# check and collect_files below see the resolved file. ENQ_FILES still overrides.
if [[ ! -f "$TASK_FILE" ]]; then
  ARCHIVED_TASK="$(ls -1 "$HISTORY_DIR"/*-"${ID}"-*.md 2>/dev/null | sort | tail -1)"
  [[ -n "$ARCHIVED_TASK" ]] && TASK_FILE="$ARCHIVED_TASK"
fi
# shellcheck source=followup-dedup.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/followup-dedup.sh"

log_enq() {
  mkdir -p "$(dirname "$HEARTBEAT")" 2>/dev/null || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$HEARTBEAT" 2>/dev/null || true
}

# --- Anti-recursion: a source task carrying followup_for: must spawn nothing ----
if [[ "${ENQ_FOLLOWUP_FOR:-0}" == "1" ]] \
   || { [[ -f "$TASK_FILE" ]] && grep -qE '^followup_for:[[:space:]]*\S' "$TASK_FILE" 2>/dev/null; }; then
  log_enq "enqueue — skip $ID (followup_for: present; anti-recursion)"
  exit 0
fi

# --- Resolve the source task's changed files -----------------------------------
# Union of every `files_changed:` line across the task file's phase blocks, or the
# ENQ_FILES override. Accepts "[a, b]" / "a b" / "none".
collect_files() {
  if [[ -n "${ENQ_FILES:-}" ]]; then
    printf '%s\n' "$ENQ_FILES"
    return 0
  fi
  local out=""
  if [[ -f "$TASK_FILE" ]]; then
    out="$(grep -E '^files_changed:' "$TASK_FILE" 2>/dev/null \
      | sed -E 's/^files_changed:[[:space:]]*//')"
  fi
  # Phase-log fallback: the inline model-path Completion sometimes records the
  # aggregate `files_changed:` only in per-phase LOG files
  # (.orchestrate/logs/{ID}-phaseN.log), leaving the task file / archive phase
  # blocks with just `summary:`/`acceptance_criteria`. When NEITHER the task file
  # nor the archived copy (TASK_FILE is already archive-resolved above) yields a
  # `files_changed:` line, scan the phase logs before concluding "no code change".
  # Collected paths flow through the SAME is_code_change predicate below.
  if [[ -z "$out" ]]; then
    out="$(grep -hE '^files_changed:' "$ROOT/.orchestrate/logs/${ID}-phase"*.log 2>/dev/null \
      | sed -E 's/^files_changed:[[:space:]]*//')"
  fi
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

# is_code_change — true (0) iff the file list contains >=1 code/test/script file
# after removing docs/log/registry/archive/control-plane paths (R-1 Decision 2).
is_code_change() {
  local raw tok
  raw="$(collect_files | tr ',[]' '   ')"
  local found=1
  for tok in $raw; do
    [[ -z "$tok" || "$tok" == "none" || "$tok" == '"none"' ]] && continue
    tok="${tok%\"}"; tok="${tok#\"}"
    tok="${tok%\'}"; tok="${tok#\'}"
    # EXCLUDE: docs, logs, registry, archives, control-plane writes.
    case "$tok" in
      *.md|*.mdx|*.txt) continue ;;
      *.log|*/logs/*|*.orchestrate/logs/*) continue ;;
      # Watermark/state sidecars are data, not code. A bare `wiki-ingest-state.json`
      # token (no `logs/` path segment) would otherwise fall through to the
      # `*.json) found=0` config branch below and spuriously enqueue review+tests
      # on a zero-code wiki/docs run. Match bare-or-path `*-state.json`.
      *-state.json) continue ;;
      */project.md|*.orchestrate/project.md) continue ;;
      */MANIFEST.md|*/orchestrate-history/*) continue ;;
      *.orchestrate/notes/*|*.orchestrate/inbox/*) continue ;;
    esac
    # CODE: behavior-bearing source/script/config files.
    case "$tok" in
      *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) found=0 ;;
      *.py|*.go|*.rs|*.rb|*.java|*.kt|*.ex|*.exs) found=0 ;;
      *.sh|*.bash) found=0 ;;
      *.sql) found=0 ;;
      *.yaml|*.yml|*.json|*.toml) found=0 ;;
      Dockerfile|*/Dockerfile|Makefile|*/Makefile|*.plist) found=0 ;;
    esac
    [[ $found -eq 0 ]] && break
  done
  return $found
}

# Distinguish "genuinely no code change (docs-only / explicit none)" from
# "no files_changed source found ANYWHERE". A completed code task whose live task
# file was deleted (Completion step 1) with an archive that lacks the line and no
# phase log yields an EMPTY collect_files — the is_code_change loop then iterates
# zero times and would fall into the SAME quiet "no code change" skip below,
# silently swallowing a missed review+tests enforcement. When there is NO source
# at all we cannot classify, so emit a DISTINCT heartbeat WARN (auditable) instead
# of a silent skip. A present-but-all-docs list (or explicit "none") is non-empty
# here and STILL takes the quiet skip — that legitimate behavior is unchanged.
if [[ -z "${ENQ_FILES:-}" ]]; then
  COLLECTED="$(collect_files)"
  if [[ -z "${COLLECTED//[[:space:]]/}" ]]; then
    log_enq "enqueue — WARN $ID: completed task has no files_changed source (task file, archive, phase logs) — cannot classify; review+tests NOT enqueued"
    echo "enqueue-review-and-tests.sh: WARN $ID has no files_changed source anywhere — cannot classify; nothing enqueued" >&2
    exit 1
  fi
fi

if ! is_code_change; then
  log_enq "enqueue — skip $ID (no code change; nothing enqueued)"
  echo "enqueue-review-and-tests.sh: task $ID has no code changes — nothing enqueued" >&2
  exit 1
fi

# --- Source title for the generated ticket headings ----------------------------
source_title() {
  local t=""
  if [[ -f "$TASK_FILE" ]]; then
    t="$(grep -m1 -E '^(# Task:|task:)' "$TASK_FILE" 2>/dev/null | sed -E 's/^(# Task:|task:)[[:space:]]*//')"
  fi
  if [[ -z "$t" && -f "$PROJ" ]]; then
    t="$(awk -F'|' -v id="$ID" '
      /^\|[[:space:]]*[0-9]/ {
        rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
        if (rid==id) { s=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); print s; exit }
      }' "$PROJ")"
  fi
  [[ -n "$t" ]] && printf '%s' "$t" || printf 'task %s' "$ID"
}

# --- Dedup: does a (followup_for, kind) ticket already exist anywhere? ----------
pair_exists() {
  local kind="$1"
  followup_pair_exists "$ROOT" "$ID" "$kind"
}

write_ticket() {
  local kind="$1" title="$2" stamp="$3"
  local heading body_action body_cmd
  if [[ "$kind" == "review" ]]; then
    heading="Review of ${title}"
    body_action="Run an independent code-change review pass over the diff produced by task \`${ID}\`."
    body_cmd="- Run \`/smart-code-review\` (or the diff review pass) scoped to \`${ID}\`'s change.
- Confirm the change matches its acceptance criteria and flag any correctness or security issue."
  else
    heading="Tests for ${title}"
    body_action="Author or run tests for the files changed by task \`${ID}\`."
    body_cmd="- Add or extend tests covering the changed files, then run the project test suite.
- Confirm the suite passes (or record \"no test runner detected\")."
  fi
  local fname="followup-${kind}-${ID}-${stamp}.md"
  local dest="$INBOX/$fname"
  mkdir -p "$INBOX"
  cat > "$dest" <<EOF
followup_for: ${ID}
kind: ${kind}
mode: auto
source: self
triggered_by: ${ID}

# ${heading}

## Goal
${body_action}

## Context
Auto-enqueued follow-up to completed task \`${ID}\` — ${title}.
This is the independent ${kind} pass that supplements the inline gate (R-1 Decision 3).

## Acceptance Criteria
${body_cmd}
EOF
  printf '%s\n' "$fname"
}

TITLE="$(source_title)"
STAMP="$(date -u +%Y%m%dT%H%M%S)"
WROTE=0

for kind in review tests; do
  if pair_exists "$kind"; then
    log_enq "enqueue — skip $ID kind=$kind (dedup: already exists)"
    continue
  fi
  fname="$(write_ticket "$kind" "$TITLE" "$STAMP")"
  log_enq "enqueue — filed $fname (followup_for $ID, kind $kind)"
  WROTE=$(( WROTE + 1 ))
done

echo "enqueue-review-and-tests.sh: $ID — wrote $WROTE follow-up ticket(s)" >&2
exit 0
