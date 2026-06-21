---
name: orchestrate-daily-wiki-ingest
description: Ingest orchestration history from the past 24 hours into the Obsidian wiki, then archive MANIFEST entries older than 30 days.
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

## Step 2 — Select jobs from the past 24 hours

Read `orchestrate-history/MANIFEST.md`. For each data line matching `YYYY-MM-DD | filename | summary | tags`:

- Parse the date column and the filename.
- Include the entry if its date is within the last 24 hours (compare using epoch seconds; date-only entries use midnight local time).

Also include entries whose archive filename starts with today's or yesterday's `YYYYMMDD` prefix when the manifest date column is ambiguous.

Build a list: `[{ date, filename, summary, tags }]`

If empty: skip Step 3–4 content creation but still run Step 5 (archive prune) and Step 6 (log).

---

## Step 3 — Write per-job wiki pages

For each selected entry:

1. Read `orchestrate-history/<filename>`.
2. Extract from the archive file:
   - `task:` line (original task description)
   - `total_phases:` and completed phase summaries / checkpoints
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
phases: <total_phases value>
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

## Step 7 — Log and report

Append to `.orchestrate/logs/wiki-ingest-daily.log`:

```
[<ISO>] wiki-ingest — jobs: N | archived: N | vault: <path>
```

Stdout summary:

```
orchestrate-daily-wiki-ingest complete
  Jobs ingested:  N
  Archived:       N (>30 days)
  Vault:          <path>
  Log:            .orchestrate/logs/wiki-ingest-daily.log
```
