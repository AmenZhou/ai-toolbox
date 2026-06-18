# daily-inbox-digest

Generates a daily digest page at 5pm from the orchestration control plane — processed inbox jobs, completed tasks, activity summary, and open items. Writes to `obsidian/Daily/YYYY-MM-DD.md` or `docs/daily/YYYY-MM-DD.md`.

## Install

```bash
# From the ai-toolbox repo root
PROJECT_DIR="$HOME/apps/ai-console"   # your project root

sed "s|/Users/haimengzhou/apps/ai-console|$PROJECT_DIR|g" \
  skills/daily-inbox-digest/com.orchestrate.daily-digest.plist \
  > ~/Library/LaunchAgents/com.orchestrate.daily-digest.plist

launchctl load ~/Library/LaunchAgents/com.orchestrate.daily-digest.plist
```

## Manual run

```bash
# From your project root (e.g. ~/apps/ai-console)
cursor-agent -p --trust /daily-inbox-digest
```

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.orchestrate.daily-digest.plist
rm ~/Library/LaunchAgents/com.orchestrate.daily-digest.plist
```

## Output

- **Wiki:** `obsidian/Daily/YYYY-MM-DD.md` (if `obsidian/` exists)
- **Fallback:** `docs/daily/YYYY-MM-DD.md`
- **Log:** `.orchestrate/logs/daily-digest.log`

If the page for today already exists, the skill appends an `## Update — HH:MM` section rather than overwriting.

## Customizing

The skill is self-contained in `SKILL.md`. Edit the sections to change what's collected or how the digest is formatted.
