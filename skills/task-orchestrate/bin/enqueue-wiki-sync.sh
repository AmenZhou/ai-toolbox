#!/usr/bin/env bash
# enqueue-wiki-sync.sh — auto-enqueue a `kind: wiki-sync` follow-up inbox
# ticket for EVERY completed task (subject only to the two anti-recursion
# guards below), so a FRESH tend cycle can capture its outcome into the
# Obsidian wiki via /wiki-capture immediately, instead of waiting for the
# daily batch job (orchestrate-daily-wiki-ingest, which is untouched and
# keeps writing the operational Orchestration/Daily/ activity log for every
# task unconditionally — this is a complementary, faster, selective path to
# real knowledge pages, not a replacement).
#
# Structurally mirrors enqueue-review-and-tests.sh (same env var contract,
# same dedup helper) but fires unconditionally (subject to the anti-recursion
# guards) rather than gating on code-change/research-keyword status, and
# writes a single `kind: wiki-sync` ticket instead of two. Does NOT touch
# enqueue-review-and-tests.sh — the two scripts are independent and may both
# fire for the same task (e.g. a code change gets both a review+tests ticket
# and a wiki-sync ticket — intended).
#
# Contract:
#   - Trigger: fires for every completed task, EXCEPT the two anti-recursion
#     cases below. (Prior to 2026-07-25 this only fired for zero-code-change
#     or research-keyword-tagged tasks — WIKI-1 broadened it to every task,
#     since a code-changing task with no research signal, e.g. a plain bug
#     fix, was otherwise never captured into the wiki at all.)
#   - Anti-recursion: if the SOURCE task itself carries a `followup_for:`
#     header (it IS already a follow-up ticket), enqueue NOTHING (exit 0).
#     Also skips (exit 0) when the source task's title/tags match a wiki-*
#     job itself (wiki-ingest, wiki-capture, wiki-update,
#     orchestrate-daily-wiki-ingest, daily-wiki-digest) — avoids recursive
#     wiki-of-wiki noise.
#   - Dedup/idempotent: before writing the ticket, skip it if a ticket with
#     the same (followup_for, kind=wiki-sync) pair already exists anywhere
#     (inbox/gated/processed, registry task files, or orchestrate-history/).
#   - Gating reality: the generated ticket lands `auto` — NO `gate_reason:`
#     line — so drain-inbox keeps it `pending`.
#
# Usage:
#   ENQ_ROOT=<project-root> enqueue-wiki-sync.sh <source-task-ID>
#     reads files_changed/followup_for/title/tags from
#     $ENQ_ROOT/.orchestrate/tasks/<ID>.md
#   ENQ_FILES="a.ts b.md" enqueue-wiki-sync.sh <ID>
#     overrides the files list (for tests / when the task file is gone)
#   ENQ_FOLLOWUP_FOR=1 ...   forces the anti-recursion skip (for tests)
#
# ENQ_ROOT defaults to the current working directory. Generated tickets ALWAYS
# go to the canonical ai-console inbox unless ENQ_INBOX_ROOT overrides it
# (tests set ENQ_INBOX_ROOT=$ENQ_ROOT so writes land in the temp control
# plane).
set -euo pipefail

ID="${1:-}"
if [[ -z "$ID" ]]; then
  echo "enqueue-wiki-sync.sh: missing <source-task-ID>" >&2
  exit 2
fi

# ID is interpolated directly into TASK_FILE / archive-glob / dest ticket-name
# path construction below. No call site today passes anything but an
# internally-generated YYYYMMDD-... ID, but validate the charset defensively
# before it ever reaches path construction — otherwise a less-trusted ID
# source (e.g. "../../etc/passwd") would be a path-traversal vector
# (20260724-inbox-6D91).
if [[ ! "$ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "enqueue-wiki-sync.sh: invalid ID '$ID' — must match ^[A-Za-z0-9_-]+\$" >&2
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

# Archive fallback: the model-path Completion sequence deletes the live task
# file (step 1) BEFORE the enqueue helpers run, so without this a genuine
# task reads an absent file, finds no `files_changed`/title/tags, and is
# wrongly classified. When the live file is gone, resolve TASK_FILE to the
# newest archived copy `orchestrate-history/*-{ID}-*.md` (ID is dash-bounded
# in the archive name: {STAMP}-{ID}-{slug}.md). ENQ_FILES still overrides.
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
  log_enq "enqueue — skip $ID (followup_for present; anti-recursion)"
  exit 0
fi

# --- Source title/tags for classification and the generated ticket heading -----
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

source_tags() {
  [[ -f "$TASK_FILE" ]] || return 0
  # `|| true` neutralizes the pipeline's exit status when no `tags:` line
  # matches: this is a bare assignment (`TAGS="$(source_tags)"`), not part of
  # a pipe/if-test, so under `set -o pipefail` a plain grep miss would
  # otherwise trip `set -e` and silently abort the whole script.
  grep -E '^tags:' "$TASK_FILE" 2>/dev/null | sed -E 's/^tags:[[:space:]]*//' || true
}

TITLE="$(source_title)"
TAGS="$(source_tags)"

# --- Anti-recursion: skip when the source task IS a wiki-* job itself ----------
# Avoids recursive wiki-of-wiki noise (wiki-ingest/-capture/-update tasks, the
# daily batch ingest, and the daily digest must not spawn their own wiki-sync).
is_wiki_job() {
  printf '%s %s' "$TITLE" "$TAGS" | grep -qiE 'wiki-ingest|wiki-capture|wiki-update|orchestrate-daily-wiki-ingest|daily-wiki-digest'
}

if is_wiki_job; then
  log_enq "enqueue — skip $ID (wiki-* job; anti-recursion)"
  exit 0
fi

# --- Resolve the source task's changed files -----------------------------------
# Union of every `files_changed:` line across the task file's phase blocks, or
# the ENQ_FILES override. Accepts "[a, b]" / "a b" / "none".
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
  # Phase-log fallback: mirrors enqueue-review-and-tests.sh — when NEITHER the
  # task file nor the archived copy yields a `files_changed:` line, scan the
  # phase logs before concluding "no code change".
  if [[ -z "$out" ]]; then
    out="$(grep -hE '^files_changed:' "$ROOT/.orchestrate/logs/${ID}-phase"*.log 2>/dev/null \
      | sed -E 's/^files_changed:[[:space:]]*//')"
  fi
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

# is_code_change — true (0) iff the file list contains >=1 code/test/script
# file after removing docs/log/registry/archive/control-plane paths. Identical
# include/exclude lists to enqueue-review-and-tests.sh's predicate — reused
# verbatim (not re-derived) so the two scripts never classify the same file
# list differently.
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

# is_research_tagged — true (0) iff the source task's title/tags
# case-insensitively match any research keyword. Substring match already
# covers the documented wildcards (analyz* via "analyz", investigat* via
# "investigat"). No longer used to gate the trigger (see WIKI-1) — kept
# because it's still meaningful metadata a future consumer may want, and
# removing it would be a gratuitous behavior-adjacent deletion.
is_research_tagged() {
  printf '%s %s' "$TITLE" "$TAGS" \
    | grep -qiE 'research|analysis|analyz|investigat|audit|spike|rfc|survey|decision'
}

# --- Trigger: fires for every completed task that cleared the two
# anti-recursion guards above (followup_for present / wiki-* job self).
# is_code_change()/is_research_tagged() are intentionally not consulted here
# — WIKI-1 (2026-07-25) removed the code-change/research-keyword gate so a
# plain code-fix task (no research signal) still gets a wiki-sync follow-up.

# --- Dedup: does a (followup_for, kind=wiki-sync) ticket already exist? --------
if followup_pair_exists "$ROOT" "$ID" "wiki-sync"; then
  log_enq "enqueue — skip $ID kind=wiki-sync (dedup: already exists)"
  echo "enqueue-wiki-sync.sh: $ID — wiki-sync ticket already exists, nothing enqueued" >&2
  exit 0
fi

STAMP="$(date -u +%Y%m%dT%H%M%S)"
FNAME="followup-wiki-sync-${ID}-${STAMP}.md"
DEST="$INBOX/$FNAME"
mkdir -p "$INBOX"
cat > "$DEST" <<EOF
followup_for: ${ID}
kind: wiki-sync
mode: auto
source: self
triggered_by: ${ID}

# Wiki sync for ${TITLE}

## Goal
Capture the knowledge produced by completed task \`${ID}\` into the Obsidian wiki.

## Context
Auto-enqueued follow-up to completed task \`${ID}\` — ${TITLE}. Every
completed task gets a wiki-sync follow-up (WIKI-1, 2026-07-25) — its outcome
may contain findings, decisions, fixes, or analysis worth preserving as
durable knowledge — complementing (not replacing) the operational daily
activity log written by orchestrate-daily-wiki-ingest.

## Instructions
1. Read \`orchestrate-history/\` for the archived copy of task \`${ID}\` (or the
   live task file if it still exists) to recover its full phase output.
2. Judge whether the content is substantive (real findings, decisions,
   analysis, or research worth remembering) versus trivial/administrative.
3. If substantive, invoke \`/wiki-capture\` against that content so it is
   filed as a proper wiki page.
4. If not substantive, log a skip and write nothing — do not force a wiki
   page for trivial content.

## Acceptance Criteria
- [ ] Either a new/updated wiki page captures task \`${ID}\`'s findings, or an
      explicit skip is logged with a reason.
EOF

log_enq "enqueue — filed $FNAME (followup_for $ID, kind wiki-sync)"
echo "enqueue-wiki-sync.sh: $ID — wrote $FNAME" >&2
exit 0
