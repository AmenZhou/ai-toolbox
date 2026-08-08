## File & Destructive Operation Safety

- **ALWAYS ask the user for confirmation before deleting any files**, regardless of context or purpose
- NEVER use destructive commands (rm, del, rmdir, etc.) without explicit user confirmation
- ALWAYS ask for confirmation before any overwrite or file system modification
- NEVER overwrite important files without backup or confirmation
- ALWAYS preserve existing code unless explicitly requested to change
- When proposing file deletions, clearly explain what will be deleted and why, and wait for confirmation before proceeding
- If asked to delete files, always double-check with user
- If unsure about any destructive operation, ask for clarification
- Prioritize data safety over convenience — when in doubt, preserve rather than delete

## Canonical Orchestrate Inbox

- The single **canonical orchestrate inbox** is `/Users/haimengzhou/apps/ai-console/.orchestrate/inbox/` (gated tickets: `.../inbox/gated/`). It is the ONLY live one — the launchd jobs (`tend`, `drain-inbox`, `monitor`, `rescue`) all run with `WorkingDirectory=/Users/haimengzhou/apps/ai-console`, so nothing drains or displays any other inbox.
- ALL ticket staging — manual writes, `/orch`, or any skill — writes to that absolute path **regardless of current working directory**. Never resolve the inbox by walking up from cwd, and never stage into a project-local `.orchestrate/` (every project under `/Users/haimengzhou/apps/` has dormant ancestor/local `.orchestrate/` dirs that act as traps). (`task-breakdown`, formerly `breakdown-to-inbox`, no longer stages inbox tickets as of v3.0.0 — it writes a task-orchestrate task plan directly instead.)
- For a ticket that operates on **another repo**, keep inbox = ai-console and use **absolute paths** inside the ticket body, with `cd <repo>` before running that repo's tests.
