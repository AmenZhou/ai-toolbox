#!/usr/bin/env bash
# Enqueue a daily orchestrate-daily-wiki-ingest run for tend to pick up.
set -euo pipefail

ROOT="$(pwd)"
INBOX="$ROOT/.orchestrate/inbox"
mkdir -p "$INBOX"
STAMP="$(date +%Y%m%dT%H%M%S)"
FILE="$INBOX/wiki-ingest-daily-run-${STAMP}.md"

cat > "$FILE" << 'EOF'
# Run orchestrate-daily-wiki-ingest

## Goal
Ingest completed orchestration jobs from the past 24 hours into the Obsidian wiki, then archive history entries older than 30 days to `orchestrate-history/archive/`.

## Context
Triggered by daily launchd schedule (6pm). Skill: /orchestrate-daily-wiki-ingest. Reads `orchestrate-history/MANIFEST.md` and archive files under `orchestrate-history/`.

## Acceptance Criteria
- Wiki pages written under `Orchestration/Daily/<YYYY-MM-DD>/` for each job in the last 24h
- Daily index page created or updated
- Entries older than 30 days moved to `orchestrate-history/archive/` and removed from MANIFEST.md
- Log entry appended to `.orchestrate/logs/wiki-ingest-daily.log`
EOF

echo "enqueued $(basename "$FILE")"
if [[ "${ORCHESTRATE_SKIP_TEND:-}" != "1" ]]; then
  "$ROOT/.orchestrate/bin/run-job.sh" tend || true
fi
