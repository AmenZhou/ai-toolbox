# inbox-log-analyzer

A self-contained Cursor Agent skill that runs once daily via launchd (9am), scans `.orchestrate/logs/` for orchestration job logs, and files structured inbox tasks for every bug or enhancement opportunity it finds. It is the automatic quality layer for the task-orchestrate control plane: instead of errors silently rotting in log files, each actionable issue becomes a first-class `.orchestrate/inbox/` ticket with a Goal, Context block, and measurable Acceptance Criteria — ready to be picked up by the next orchestrate cycle.

---

## What It Looks For

### Bugs
- Lines containing `✗`, `MISSING:`, `FAIL`, `error`, `Error`, or `fatal`
- Non-zero exit codes (`exit code 1`, `exit code 2`, etc.)
- Phases that ended with `confidence: low`
- Verify runs that ended with `✗ failed`
- Stuck phase patterns — same phase retried 2 or more times

### Enhancements
- A phase section with no Acceptance Criteria block defined
- A tend.log showing a task completed with 0 phases (empty/no-op task)
- Recurring pre-existing blockers (non-empty `blockers:` field marked `pre-existing`)
- Verify logs reporting "no test runner detected" on projects that have source files

---

## Install (launchd — runs once daily at 9am)

### 1. Set your project directory

```bash
PROJECT_DIR="$HOME/apps/my-project"   # <-- change this to your project root
```

### 2. Copy and configure the plist

```bash
sed "s|~/apps/my-project|$PROJECT_DIR|g" \
  skills/inbox-log-analyzer/com.orchestrate.inbox-analyzer.plist \
  > ~/Library/LaunchAgents/com.orchestrate.inbox-analyzer.plist
```

### 3. Load the agent

```bash
launchctl load ~/Library/LaunchAgents/com.orchestrate.inbox-analyzer.plist
```

### 4. Verify it loaded

```bash
launchctl list | grep inbox-analyzer
```

### 5. Unload when done

```bash
launchctl unload ~/Library/LaunchAgents/com.orchestrate.inbox-analyzer.plist
```

---

## Run Manually

From any Cursor Agent session with your project as the working directory:

```
/inbox-log-analyzer
```

This runs all 7 cycle steps immediately and prints a summary to the console.

---

## State File

The analyzer tracks which logs it has already processed in:

```
.orchestrate/logs/inbox-analyzer-state.json
```

Format:
```json
{
  "analyzed": [
    "20240615-task-tend.log",
    "20240615-phase1.log"
  ]
}
```

**To reset** (reprocess all logs from scratch): delete the state file.

```bash
rm .orchestrate/logs/inbox-analyzer-state.json
```

The next run will treat all existing log files as unprocessed.

---

## Output Files

| File | Description |
|------|-------------|
| `.orchestrate/inbox/analyzer-<slug>-<timestamp>.md` | One file per finding, structured inbox task |
| `.orchestrate/logs/inbox-analyzer-state.json` | Persistent state: list of processed log filenames |
| `.orchestrate/logs/heartbeat.log` | Append-only cycle log: one line per run |
| `.orchestrate/logs/inbox-analyzer.log` | launchd stdout (when running via plist) |
| `.orchestrate/logs/inbox-analyzer-err.log` | launchd stderr (when running via plist) |

---

## Inbox File Format

Each generated inbox file follows the task-orchestrate structured format:

```markdown
# [BUG] <what failed> in <log-filename>

## Goal
What must be true when this is resolved. References the specific log and line.

## Context
- Source log: `.orchestrate/logs/<filename>`
- Excerpt: `<verbatim 1–3 lines from the log>`
- Task ID: <extracted from filename, or "unknown">
- Related files: <any files mentioned in the log>

## Acceptance Criteria
- Specific, measurable criterion 1
- Specific, measurable criterion 2
```

---

## Deduplication

Before writing any inbox file, the analyzer checks `.orchestrate/inbox/*.md` for existing files with a near-matching title (case-insensitive, first 60 characters). Duplicate findings are silently skipped and counted in the cycle summary as "skipped". This prevents repeated launchd runs from flooding the inbox with identical tickets.
