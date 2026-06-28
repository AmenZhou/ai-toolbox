---
name: unblock-task
description: List all needs_human tasks, show blocking reason, accept user resolution, inject human_resolution into the task file, reset to pending, kick tend.
inline: true
---

# /unblock-task

List all `needs_human` tasks from `.orchestrate/project.md`, display the blocking reason for each, accept the user's resolution text, and inject it into the blocked phase of the task file so the next tend cycle retries with that context.

## Step 1 — Scan registry

Read `.orchestrate/project.md`. Find all rows with `status: needs_human`.

If none: output "Nothing blocked. All clear." and stop.

## Step 2 — Load task files

For each `needs_human` row, read `.orchestrate/tasks/{ID}.md`. Find the first `### Phase N:` block that does NOT have `status: ✓ complete` — that is the blocking phase.

Extract:
- `phase_num`: the phase number
- `phase_name`: the phase title
- `blocking_summary`: if the task file has a phase output with `blockers:` line, use that; otherwise use the phase's `acceptance_criteria` first bullet
- `needs`: from task-level `needs:` line or `## needs` section (if present)
- `why`: from task-level `why:` line or `## why` section (if present)
- `to_clear`: from task-level `to_clear:` line or `## to_clear` section (if present)

## Step 3 — Display

```
── Blocked Tasks ──────────────────────────────────────────
[1] {ID} — {summary}
    ⚠ Blocked at Phase {N}: {phase_name}
    Reason: {blocking_summary or "(task file not found)"}
    needs: {needs or "(not specified)"}
    why: {why or "(not specified)"}
    to_clear: {to_clear or "(not specified)"}

[2] ...
──────────────────────────────────────────────────────────
Enter task number + resolution text (e.g. "1 Use p95 < 1.5s SLA"), or "skip <n>", or "abort":
```

If a task file is missing: show `(task file not found — cannot inject resolution)` and exclude from selectable items.

## Step 4 — Parse user input

| Input | Action |
|-------|--------|
| `<N> <resolution text>` | Inject resolution into task N's blocking phase |
| `skip <N>` | Skip that task; continue displaying others |
| `abort` | Exit with no changes |

If the user provides only a number without resolution text, prompt: "Please include the resolution text after the number."

Allow resolving multiple tasks sequentially: after each resolution, ask "Resolve another? (y/n)" or show remaining blocked tasks.

## Step 5 — Inject resolution

For the selected task:

1. Read `.orchestrate/tasks/{ID}.md`
2. Find the blocking phase block (first phase without `status: ✓ complete`)
3. Find the `status:` line within that phase block
4. Append `human_resolution: {user text}` on the next line after the `status:` line
5. **Clear the bypass marker:** remove any `bypassed_at:` and `bypass_reason:` lines from the task file (the task is no longer parked — the human resolution unblocks it)
6. Write the updated task file

## Step 6 — Reset and kick

1. Update `.orchestrate/project.md` registry: change `status: needs_human` → `status: pending` for this task ID
2. Update `last_activity` to current UTC ISO timestamp
3. Run `.orchestrate/bin/run-job.sh tend` in background (fire-and-forget)
4. Log to `.orchestrate/logs/heartbeat.log`: `[<ISO>] unblock-task — injected resolution for {ID} phase {N}: "{first 80 chars}"`

## Step 7 — Confirm

```
✓ Unblocked [{ID}] "{summary}"
  Phase {N}: {phase_name}
  Resolution injected — tend kicked, next cycle will retry with your answer.
```

## Edge cases

- **No task file:** Skip resolution injection for that task; notify user.
- **All phases already complete:** The task should not be in `needs_human` — log this anomaly and skip.
- **User aborts:** No changes made.
- **run-job.sh missing:** Log warning; still update registry (tend will pick it up on next launchd cycle).

## human_resolution field format

The injected line must be:
```
human_resolution: <user text verbatim>
```

This matches the format that the task-orchestrate SKILL.md execution loop reads when starting or retrying the blocking phase. After the phase completes `✓ complete`, the loop strips this line.
