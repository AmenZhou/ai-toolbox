# launchagent-watchdog

Runs every 30 minutes via launchd. Checks that all `com.orchestrate.*` and `com.inbox-zero.*` launchd jobs are:
1. Loaded (`launchctl list` shows the label)
2. Running on schedule (log updated within 2× their expected interval)
3. Not producing new stderr output

Sends a `PushNotification` and files a structured inbox task for any dead or overdue job. Alert suppression prevents repeat pings within 1 hour per job.

## Install

```bash
# From the ai-toolbox repo root
PROJECT_DIR="$HOME/apps/ai-console"   # your project root

sed "s|/Users/haimengzhou/apps/ai-console|$PROJECT_DIR|g" \
  skills/launchagent-watchdog/com.orchestrate.launchagent-watchdog.plist \
  > ~/Library/LaunchAgents/com.orchestrate.launchagent-watchdog.plist

launchctl load ~/Library/LaunchAgents/com.orchestrate.launchagent-watchdog.plist
```

## Manual run

```bash
# From your project root
claude -p /launchagent-watchdog
```

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.orchestrate.launchagent-watchdog.plist
rm ~/Library/LaunchAgents/com.orchestrate.launchagent-watchdog.plist
```

## State file

`.orchestrate/logs/launchagent-watchdog-state.json` — tracks last log size and last alert time per job. Delete to reset all alert suppression windows.

## Extending watched groups

The watchdog auto-discovers jobs by prefix. Add a new group by editing Step 1 of `SKILL.md` with the new glob pattern.
