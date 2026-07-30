---
name: launchagent-watchdog
description: Runs every 30 minutes via launchd, checks that all com.orchestrate.* and com.inbox-zero.* jobs are alive and on schedule, sends PushNotification and files inbox tasks for any dead or overdue jobs.
inline: true
---

You are the **launchagent-watchdog**: a self-contained health monitor for all managed launchd jobs. You run every 30 minutes and ensure nothing goes silently dead.

Execute the following steps in order. Do not ask for clarification — act immediately and report results at the end.

---

## Step 1 — Discover Managed Plists

Scan `~/Library/LaunchAgents/` for plists matching either prefix:
- `com.orchestrate.*`
- `com.inbox-zero.*`

```bash
ls ~/Library/LaunchAgents/com.orchestrate.*.plist 2>/dev/null
ls ~/Library/LaunchAgents/com.inbox-zero.*.plist 2>/dev/null
```

For each plist file found, parse the XML to extract:
- `Label` — the job identifier
- `StandardOutPath` — the log file to check for recency
- `StandardErrorPath` — stderr log (may equal stdout; track separately if different)
- `StartInterval` — seconds between runs (if present)
- `StartCalendarInterval` — dict with `Hour`/`Minute` (if present instead of StartInterval)

Build a job list: `[{ label, plistPath, logPath, errLogPath, intervalSecs, calendarHour, calendarMinute }]`

For calendar jobs: `intervalSecs = null`, `calendarHour`/`calendarMinute` set.
For interval jobs: `calendarHour = null`, `calendarMinute = null`.

---

## Step 2 — Load Watchdog State

Read `.orchestrate/logs/launchagent-watchdog-state.json`.

If absent or unparseable, initialize:
```json
{ "jobs": {} }
```

`state.jobs` is a map keyed by label:
```json
{
  "com.orchestrate.tend": {
    "lastLogSize": 1234,
    "lastAlertAt": "2026-01-01T00:00:00Z"
  }
}
```

---

## Step 3 — Check Each Job

For each job discovered in Step 1, run three checks:

### Check 1 — Loaded

```bash
launchctl list | grep "<label>"
```

If the label is absent: **DEAD** — job is not loaded.

### Check 2 — Recency

Read the log file at `logPath`. Find the most recent line containing an ISO timestamp (`[YYYY-MM-DDT...Z]` pattern).

**Interval jobs:** Flag as **OVERDUE** if the most recent timestamp is older than `2 × intervalSecs` seconds ago (i.e. missed at least one full cycle).

**Calendar jobs:** Flag as **OVERDUE** if:
- Current local time is past `calendarHour:calendarMinute + 30 minutes`
- AND the most recent log timestamp is from before today's scheduled run time

If the log file doesn't exist: treat as **OVERDUE** (job has never run).

### Check 3 — Error growth

If `errLogPath` exists and differs from `logPath`:
```bash
wc -c < errLogPath   # current byte count
```
Compare against `state.jobs[label].lastLogSize`. If current > lastLogSize by more than 100 bytes: flag as **ERR_GROWTH**.

---

## Step 4 — Alert Suppression

For each flagged job, check `state.jobs[label].lastAlertAt`.

If an alert was sent within the last **3600 seconds** (1 hour): skip sending alert for this job this cycle. Log internally but do not send PushNotification or file inbox task.

---

## Step 5 — Send Alerts

For each job that is flagged (DEAD, OVERDUE, or ERR_GROWTH) and is **not** suppressed:

### Push Notification

Use the `PushNotification` MCP tool:
```
title: "launchagent-watchdog: <label>"
body: "<label> — <diagnosis>" 
```

Where `<diagnosis>` is one of:
- `not loaded (launchctl list shows no entry)`
- `overdue by ~Xm (last log: <relative time>)`  
- `stderr log grew by N bytes since last check`

### Inbox Task

Write a structured task file to the **canonical ai-console inbox** (regardless of cwd) — `/Users/haimengzhou/apps/ai-console/.orchestrate/inbox/launchagent-watchdog-<slug>-<timestamp>.md`. Never stage into a cwd-relative project-local `.orchestrate/`; ai-console's is the only inbox the tend/drain/monitor jobs watch.

```markdown
# [BUG] <label> is <DEAD|OVERDUE|ERR_GROWTH>

## Goal
<label> must be running and logging within its expected interval. Currently: <diagnosis>. Reload the agent or investigate the cause.

## Context
- Plist: ~/Library/LaunchAgents/<plist filename>
- Log path: <logPath>
- Last log line: <last 1 line from logPath, or "log file not found">
- launchctl output:
  ```
  <output of: launchctl list | grep label, or "(not listed)">
  ```
- Diagnosis: <DEAD / OVERDUE by Xm / ERR_GROWTH N bytes>

## Acceptance Criteria
- `launchctl list | grep <label>` shows the job loaded with PID or exit 0
- Log file updated within expected window after fix
- No new ERR_GROWTH flags in next watchdog cycle
```

---

## Step 6 — Update State

For each job checked:
- Update `state.jobs[label].lastLogSize` to current stderr byte count (or 0 if file absent)
- If alert was sent this cycle: update `state.jobs[label].lastAlertAt` to current ISO timestamp
- If no alert (healthy or suppressed): leave `lastAlertAt` unchanged

Write updated state to `.orchestrate/logs/launchagent-watchdog-state.json`.

---

## Step 7 — Log Cycle

Append to `.orchestrate/logs/heartbeat.log`:

```
[<ISO timestamp>] launchagent-watchdog — checked <N> jobs, flagged <F>, alerted <A>, suppressed <S>
```

Then output summary to stdout:

```
launchagent-watchdog complete
  Jobs checked:  N
  Flagged:       F (DEAD: X, OVERDUE: Y, ERR_GROWTH: Z)
  Alerted:       A
  Suppressed:    S (within 1-hour window)
  State:         .orchestrate/logs/launchagent-watchdog-state.json updated
```

---

## Extending Watched Groups

The watchdog discovers jobs dynamically by prefix — `com.orchestrate.*` and `com.inbox-zero.*`. To add a new group:
1. Install the plist in `~/Library/LaunchAgents/` with a label matching one of the watched prefixes.
2. No code changes needed — the watchdog picks it up on the next cycle.

To watch a different prefix group: edit Step 1 of this SKILL.md to add the new `ls` glob pattern.
