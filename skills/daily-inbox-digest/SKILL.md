---
name: daily-inbox-digest
description: Daily 5pm digest — collects today's processed inbox jobs and completed orchestration tasks, then writes a summary page to the Obsidian wiki (or docs/daily/ fallback).
inline: true
---

You are the **daily-inbox-digest**: a self-contained digest agent that runs once per day (via launchd at 17:00) and produces a structured daily summary page from the orchestration control plane.

Execute the following steps in order. Do not ask for clarification — act immediately and report results at the end.

---

## Step 1 — Determine Today's Date

```bash
TODAY=$(date +%Y-%m-%d)
TODAY_PREFIX=$(date -u +%Y-%m-%dT)   # ISO prefix for filtering heartbeat lines
```

All filtering in subsequent steps uses `$TODAY` (local date) for file mtimes and manifest lines.

---

## Step 2 — Collect Today's Processed Inbox Jobs

> **Read-only against the canonical inbox.** This skill does NOT stage inbox task files — it only *reads* the live ai-console control plane (`/Users/haimengzhou/apps/ai-console/.orchestrate/inbox/processed/`) and writes its digest to the Obsidian wiki / `docs/daily/` fallback. It runs under cwd=ai-console, so the cwd-relative reads below are correct; no inbox-write pin is needed.

Scan `.orchestrate/inbox/processed/` for `.md` files whose modification date matches today.

```bash
find .orchestrate/inbox/processed -name "*.md" -newer /tmp/today-start 2>/dev/null
# Alternative: find . -name "*.md" and filter by mtime matching today
```

For each file: read the first line (`# Title`) and the first sentence after `## Goal` (up to the first `.` or newline). Build a list:
```
[{ filename, title, goal_first_sentence }]
```

If none found: list is empty (handled gracefully in Step 5).

---

## Step 3 — Collect Today's Completed Tasks

Read `orchestrate-history/MANIFEST.md`. Filter lines where the date field (first column before `|`) matches `$TODAY`.

For each matching line: extract filename, summary, tags. Load the archive file from `orchestrate-history/<filename>` and extract:
- `task:` field (original task description)
- `total_phases:` count
- `tags:` line

Build a list:
```
[{ filename, summary, phases, tags }]
```

If none found: list is empty.

---

## Step 4 — Collect Activity Summary

Read `.orchestrate/logs/heartbeat.log`. Extract all lines that start with `[$TODAY` (ISO prefix match). Keep the last 50 matching lines.

Synthesize 3–5 bullet points describing:
- What automated jobs ran (tend cycles, inbox-analyzer)
- How many inbox tasks were filed
- Any failures or warnings visible in the log
- Notable tasks started or completed

If heartbeat.log is absent or has no today-lines: write "No heartbeat activity recorded today."

---

## Step 5 — Collect Open Items

Read `.orchestrate/project.md`. Extract all registry rows with status `pending`, `running`, or `needs_human`. Format each as:
- `**[ID]** summary — status: <status>`

---

## Step 6 — Determine Output Path

Check if `obsidian/` directory exists in the working directory (`.`):

```bash
[ -d "obsidian" ] && WIKI_AVAILABLE=true || WIKI_AVAILABLE=false
```

- **Wiki available:** output to `obsidian/Daily/$TODAY.md` — create `obsidian/Daily/` if needed.
- **Fallback:** output to `docs/daily/$TODAY.md` — create `docs/daily/` if needed.

**Duplicate page guard:** If the output file already exists, do not overwrite it. Instead append a new `## Update — HH:MM` section at the end of the existing file.

```bash
UPDATE_TIME=$(date +%H:%M)
```

---

## Step 7 — Write the Digest Page

If creating a new page:

```markdown
# Daily Digest — YYYY-MM-DD

## Inbox Jobs Processed (N)

<!-- Hidden when N=0 — omit this section entirely if list is empty -->
- **<job title>** — <goal first sentence> `[source: filename]`

## Tasks Completed (N)

<!-- Hidden when N=0 — omit this section entirely if list is empty -->
- **<task summary>** — phases: X | tags: <tags> `[archive: filename]`

## Activity Summary

- <bullet 1 synthesized from heartbeat>
- <bullet 2>
- <bullet 3>

## Open Items

<!-- Hidden when list is empty -->
- **[ID]** summary — status: <status>
```

If N=0 for both Inbox Jobs and Tasks Completed, still write the page with those sections omitted and a note: "Quiet day — no inbox jobs processed and no tasks completed."

If appending to an existing page:

```markdown

## Update — HH:MM

### Inbox Jobs (+N)
- **<title>** — <goal> `[source: filename]`

### Tasks Completed (+N)
- **<summary>** — phases: X `[archive: filename]`

### Activity
- <1–3 bullets>
```

---

## Step 8 — Write Log Entry

Append to `.orchestrate/logs/daily-digest.log`:

```
[<ISO timestamp>] daily-digest — wrote <output path> | inbox: N | tasks: N | open: N
```

Then output a brief summary to stdout:

```
daily-inbox-digest complete
  Date:    YYYY-MM-DD
  Output:  <full path to digest page>
  Inbox:   N job(s) processed
  Tasks:   N completed
  Open:    N open items
  Log:     .orchestrate/logs/daily-digest.log updated
```
