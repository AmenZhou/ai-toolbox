---
name: claude-exec
description: >
  Delegate a task to Claude Code CLI. Use when the user wants to run a Claude Code skill or plain
  prompt via Claude Code — e.g. "/claude-exec /task-orchestrate refactor auth", "/claude-exec
  /smart-code-review", "/claude-exec add error handling to main.js". Also triggers on: "run claude
  code", "use claude to do", "have claude code do", "invoke claude code", "delegate to claude code",
  "ask claude code to". Handles project directory resolution, permission flags, and output display.
---

# Claude Exec — Delegate to Claude Code CLI

You invoke `claude -p` (Claude Code non-interactive mode) to execute a skill or prompt inside a specific project directory.

## Step 1: Resolve the target directory

1. Check conversation context — has the user said "switch to [project]" or mentioned a project recently?
2. If yes, look up the path from `/Users/haimengzhou/apps/ai-console/workspace.local.md`.
3. If no project context, use the current working directory (CWD).
4. If ambiguous, ask: "Which project should Claude Code run in?"

## Step 2: Resolve the prompt

The user's argument after `/claude-exec` is passed directly to Claude Code. Examples:
- `/claude-exec /task-orchestrate refactor the auth module` → prompt is `/task-orchestrate refactor the auth module`
- `/claude-exec /smart-code-review` → prompt is `/smart-code-review`
- `/claude-exec add error handling to utils.js` → prompt is `add error handling to utils.js`

Strip the `/claude-exec` prefix. Pass everything else verbatim as the Claude Code prompt.

## Step 3: Choose permission mode

| Scenario | Flag |
|---|---|
| Default / safe | `--permission-mode auto` |
| User says "auto-approve" or "no prompts" | `--permission-mode dontAsk` |
| User says "full auto" or "bypass permissions" | `--dangerously-skip-permissions` |

Default to `--permission-mode auto` unless the user specifies otherwise.

## Step 4: Run Claude Code

```bash
cd <resolved-project-path> && claude -p "<prompt>" --permission-mode auto
```

- Always `cd` into the project directory first — this ensures CLAUDE.md and .claude/settings.json are discovered correctly.
- Stream the output directly to the user.
- If the command exits non-zero, report the error and exit code.

## Step 5: Report result

After Claude Code finishes:
- Show a brief summary of what it did (or echo the final output if it's short).
- If there were errors, quote them and suggest next steps.
- Do NOT re-run automatically unless the user asks.

## Examples

**User:** `/claude-exec /task-orchestrate add unit tests to the auth module`
→ Runs: `cd /Users/haimengzhou/apps/<current-project> && claude -p "/task-orchestrate add unit tests to the auth module" --permission-mode auto`

**User:** `have claude code run smart-code-review on the ml-ds-tutorial`
→ Resolves path from workspace.local.md, runs: `cd /Users/haimengzhou/apps/ml-ds-tutorial && claude -p "/smart-code-review" --permission-mode auto`

**User:** `/claude-exec /task-orchestrate migrate db schema` with "no prompts"
→ Runs: `cd <path> && claude -p "/task-orchestrate migrate db schema" --permission-mode dontAsk`
