---
name: hotel-agent-analyze
description: Alias for web-game-agent-analyze. Run Playwright JSONL agent, analyze logs, fix bugs — works for run-a-hotel, jet-pilot-simulator, and similar web games. Prefer invoking web-game-agent-analyze.
version: 2.0.0
---

# hotel-agent-analyze (alias)

This skill is an **alias** for **[web-game-agent-analyze](../web-game-agent-analyze/SKILL.md)**.

When the user invokes `/hotel-agent-analyze` or asks to analyze a game agent log:

1. Read and follow **`~/.claude/skills/web-game-agent-analyze/SKILL.md`** in full.
2. Auto-detect the project profile from the current working directory (hotel vs jet earth vs arcade).
3. Do not assume run-a-hotel unless marker files match that profile.

For **Grand Hotel** specifically, use profile `run-a-hotel` and defaults `--turns 20 --tick 4000 --model openai`.

For **Jet Pilot Fly Earth**, use profile `jet-pilot-earth` and read **`jet-pilot-simulator/ai-agent/SKILL.md`** for log signatures and UX checklist.
