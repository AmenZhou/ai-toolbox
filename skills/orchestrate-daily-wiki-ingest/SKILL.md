---
name: orchestrate-daily-wiki-ingest
description: Ingest orchestration history newer than the last-successful-ingest watermark (catching up any missed runs; falls back to a 24h window on first run) into the Obsidian wiki, then archive MANIFEST entries older than 30 days.
---

You are **orchestrate-daily-wiki-ingest**: distill recent completed orchestration runs into the Obsidian wiki and prune old history archives.

Execute all steps in order. Do not ask for clarification.

---

## Step 1 — Resolve vault path

Walk up from the working directory for `.env` containing `OBSIDIAN_VAULT_PATH`. If not found, read `~/.obsidian-wiki/config`. If still unset and `obsidian/` exists in cwd, use `$(pwd)/obsidian` as fallback.

```bash
VAULT=""
# try .env in cwd
if [[ -f .env ]] && grep -q '^OBSIDIAN_VAULT_PATH=' .env 2>/dev/null; then
  VAULT="$(grep '^OBSIDIAN_VAULT_PATH=' .env | cut -d= -f2- | tr -d '"'"'"' | tr -d ' ')"
fi
# try global config
if [[ -z "$VAULT" && -f "$HOME/.obsidian-wiki/config" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.obsidian-wiki/config"
  VAULT="${OBSIDIAN_VAULT_PATH:-}"
fi
# fallback
if [[ -z "$VAULT" && -d obsidian ]]; then
  VAULT="$(pwd)/obsidian"
fi
if [[ -z "$VAULT" || ! -d "$VAULT" ]]; then
  echo "ERROR: OBSIDIAN_VAULT_PATH not resolved" >&2
  exit 1
fi
```

Wiki output root: `$VAULT/Orchestration/Daily/`

Link format: use `[[wikilinks]]` unless `OBSIDIAN_LINK_FORMAT=markdown` is set in config.

---

## Step 2 — Select jobs newer than the last-ingested watermark

A fixed "past 24 hours" window silently loses work across any missed run: if the daily launchd job is dead or ghost-reset for a day, every job completed in that gap ages out of the window and is dropped forever. Select by a **persisted watermark** instead, so a missed run is caught up on the next successful one.

**Watermark store:** `.orchestrate/logs/wiki-ingest-state.json`, shape:

```json
{ "last_ingested_stamp": "YYYYMMDD-HHMMSS" }
```

`last_ingested_stamp` is the archive-filename prefix (`YYYYMMDD-HHMMSS`) of the newest entry successfully ingested by a prior run. The prefix is lexicographically sortable, so string comparison is a valid time comparison.

**Selection algorithm:**

1. Read the watermark:
   ```bash
   STATE=".orchestrate/logs/wiki-ingest-state.json"
   WATERMARK=""
   if [[ -f "$STATE" ]]; then
     WATERMARK="$(grep -o '"last_ingested_stamp"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE" | sed 's/.*"\([^"]*\)"$/\1/')"
   fi
   ```
2. Read `orchestrate-history/MANIFEST.md`. For each data line matching `YYYY-MM-DD | filename | summary | tags`, parse the date column and the filename. Derive the entry's stamp from the filename's leading `YYYYMMDD-HHMMSS` prefix (fall back to `<date-with-dashes-removed>-000000` when the filename has no time component).
3. **Include** the entry when:
   - a watermark exists AND the entry stamp is **lexicographically greater than** the watermark; **OR**
   - no watermark exists (first run / fresh state) AND the entry date is within the last 24 hours (the original rolling-window fallback — epoch seconds; date-only entries use midnight local time).
4. **Sort** the included list ascending by stamp (oldest first) — so a per-run cap ingests the oldest backlog first and the watermark advances monotonically.

Build a list: `[{ stamp, date, filename, summary, tags }]`.

**Dedup:** drop any entry whose `sources: [orchestrate-history/<filename>]` page already exists under `$VAULT/Orchestration/Daily/**` (a re-run must never double-write). Dedup by `task_id`/`sources`, not by date.

**Per-run cap (overflow deferred, never dropped):** cap the run at `WIKI_INGEST_CAP` entries (default 100). If more than the cap qualify, ingest the **oldest** `CAP` of them this run and leave the remainder untouched — because the watermark advances only to the newest *ingested* stamp (Step 7), the deferred entries stay above the watermark and are picked up on the next run. Log the deferred count in Step 7.

If the selected list is empty: skip Step 3–4 content creation but still run Step 5 (archive prune) and Step 6 (log). Do **not** advance the watermark when nothing was ingested.

---

## Step 3 — Write per-job wiki pages

For each selected entry:

1. Read `orchestrate-history/<filename>`.
2. Extract from the archive file:
   - `task:` line (original task description)
   - `total_phases:` and completed phase summaries / checkpoints. If the `total_phases:` line is absent, derive the phase count with `grep -c '^### Phase' orchestrate-history/<filename>` — never emit `?`.
   - Any `## Shared Context` or improvement suggestions blocks if present
   - `tags:` line from frontmatter or manifest
3. Derive slug from filename (strip `.md`, remove date prefix).
4. Write or update `$VAULT/Orchestration/Daily/<YYYY-MM-DD>/<slug>.md` with frontmatter:

```yaml
---
title: <summary>
category: orchestration
tags: [orchestration, daily-ingest, <tags from manifest>]
sources: [orchestrate-history/<filename>]
created: <YYYY-MM-DD>
updated: <today ISO date>
task_id: <id from archive if present>
phases: <total_phases value, or `grep -c '^### Phase' <archive>` when total_phases is absent>
status: complete
---
```

Body sections:
- **Summary** — one paragraph from manifest summary + task line
- **What changed** — bullet list from phase checkpoints / PHASE OUTPUT summaries
- **Learnings** — bullets from Shared Context updates or Improvement Suggestions (omit section if none)

Compile into existing pages — do not duplicate if the page already exists for the same `sources` entry.

---

## Step 4 — Write daily index page

For each date folder touched, create or update `$VAULT/Orchestration/Daily/<YYYY-MM-DD>/index.md`:

```markdown
# Orchestration Daily — YYYY-MM-DD

| Task | Phases | Tags |
|------|--------|------|
| [[<slug>]] | N | tag1, tag2 |
```

`N` is the page's `phases:` value (the `total_phases:` value, or the `grep -c '^### Phase'` fallback when absent) — never `?`.

One-line summary per job below the table.

---

## Step 5 — Archive history older than 30 days

After wiki ingest:

1. `mkdir -p orchestrate-history/archive`
2. Read `orchestrate-history/MANIFEST.md` — preserve header comments and `---` separators.
3. For each data line, parse date (first column) and filename (second column). Also parse `YYYYMMDD` from filename prefix when present — use the **older** of the two dates for safety.
4. If entry date is **more than 30 days** before today:
   - `mv orchestrate-history/<filename> orchestrate-history/archive/<filename>` (skip if already archived)
   - Exclude from new manifest
5. Rewrite `MANIFEST.md` with header + remaining entries (same format).
6. Record count: `archived N entries older than 30 days`

Do **not** delete files — only move to `archive/`.

---

## Step 6 — Stage commit (optional)

If `WIKI_STAGED_WRITES=true` in environment or config, run `/wiki-stage-commit` for pages written this run.

---

## Step 7 — Advance watermark, log and report

**Advance the watermark (only when ≥1 job was ingested this run):** write the newest *ingested* entry's stamp to `.orchestrate/logs/wiki-ingest-state.json`. Because the Step 2 list is sorted oldest-first and capped, the newest ingested stamp is the last element actually written this run — NOT the newest qualifying entry (any capped overflow must remain above the watermark so the next run catches it).

```bash
# NEWEST_INGESTED_STAMP = stamp of the last (newest) entry ingested this run
if [[ -n "$NEWEST_INGESTED_STAMP" ]]; then
  printf '{ "last_ingested_stamp": "%s" }\n' "$NEWEST_INGESTED_STAMP" > .orchestrate/logs/wiki-ingest-state.json
fi
```

If zero jobs were ingested, leave the watermark unchanged.

Append to `.orchestrate/logs/wiki-ingest-daily.log`:

```
[<ISO>] wiki-ingest — jobs: N | deferred: N | archived: N | watermark: <stamp> | vault: <path>
```

Stdout summary:

```
orchestrate-daily-wiki-ingest complete
  Jobs ingested:  N
  Deferred:       N (over per-run cap; caught next run)
  Archived:       N (>30 days)
  Watermark:      <stamp>
  Vault:          <path>
  Log:            .orchestrate/logs/wiki-ingest-daily.log
```
