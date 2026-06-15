# task-orchestrate

A unified project orchestrator for Claude Code. Break any task into structured phases, keep a shared control plane across all work in a project, and let the built-in watchdog keep things moving automatically.

---

## What it does

- **Decomposes** your task into 2–6 phases and routes each to the right sub-skill or runs it inline
- **Keeps shared context** in `.orchestrate/project.md` — every task in a project shares the same state
- **Runs a watchdog** (`tend` mode) via a background launchd job that drains the inbox, advances stalled tasks, and notifies when human input is needed
- **Gates or auto-runs** — you choose whether to approve each phase or let the whole task run unattended

---

## Invocation modes

| Input | What happens |
|-------|-------------|
| `tend` | Watchdog cycle: drain inbox, advance stalled tasks, send notifications |
| `status` | Health snapshot: background job, lock age, heartbeat, registry counts |
| `resume` | List active tasks and pick one to continue |
| `enqueue <description>` | Drop a task into `.orchestrate/inbox/` for later background processing |
| Any other text | Plan and execute a new task |
| *(empty)* | Show registry status if a project exists; otherwise ask for a task |

---

## Project state layout

All state lives under `.orchestrate/` in your working directory:

```
.orchestrate/
  project.md          # shared context + task registry
  tasks/              # per-task phase files
  inbox/              # drop-zone: a .md file here = a task to pick up
  logs/
    heartbeat.log     # one line per tend cycle
```

---

## Interaction model

After a plan is presented:

| Reply | Effect |
|-------|--------|
| `go` | Execute the next phase, then pause for review |
| `go auto` | Run all remaining phases without gates |
| *(describe a change)* | Revise the plan, then re-present |
| `abort` | Stop immediately |

On phase failure:

| Reply | Effect |
|-------|--------|
| `retry` | Re-run the failed phase |
| `skip` | Skip it and continue |
| `replan` | Revise remaining phases |
| `abort` | Stop |

---

## Background watchdog setup (macOS)

Install a launchd job to run `tend` every 5 minutes:

```bash
PROJECT_DIR="$HOME/apps/my-project"  # adjust to your project root
LOG_DIR="$PROJECT_DIR/.orchestrate/logs"
mkdir -p "$LOG_DIR"

cat > ~/Library/LaunchAgents/com.orchestrate.tend.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.orchestrate.tend</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/claude</string>
    <string>-p</string>
    <string>tend</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>WorkingDirectory</key><string>$PROJECT_DIR</string>
  <key>StandardOutPath</key><string>$LOG_DIR/heartbeat.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/heartbeat-err.log</string>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.orchestrate.tend.plist
```

After this, the watchdog runs permanently in the background — no loop to start or maintain.

---

## Example session

```
/task-orchestrate add rate limiting to all API endpoints and write tests

# Claude decomposes into phases and presents a plan
# You reply:

go auto

# All phases run — research, implementation, tests, PR — unattended
```

Enqueueing work for later:

```
/task-orchestrate enqueue update the API docs for the new rate limiting headers
```

That drops a file in `.orchestrate/inbox/`. The next `tend` cycle picks it up automatically.

---

## Files in this directory

| File | Purpose |
|------|---------|
| `SKILL.md` | Full skill instructions loaded by Claude Code |
| `GUIDE.md` | Use cases, examples, and setup walkthrough |
| `README.md` | This overview |
