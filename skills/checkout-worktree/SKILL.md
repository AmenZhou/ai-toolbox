---
name: checkout-worktree
description: Creates a new git worktree folder under ~/apps for a ticket branch, then registers it in workspace.local.md. Use when starting work on a new ticket that needs its own isolated checkout of an existing repo.
inline: true
---

# Checkout Worktree

Creates a new git worktree for a ticket branch and registers it in the workspace registry.

---

## Inputs (resolve before starting)

| Input | Example | Notes |
|-------|---------|-------|
| `folder_name` | `ds-3` | Name for the new folder under `~/apps/` |
| `source_repo` | `/Users/haimengzhou/apps/dsp_stress_test` | Absolute path to the source git repo |
| `branch_name` | `feature/phase2-ds3-seed-verification` | New branch to create; follow repo's naming convention |

If any input is missing, ask the user before proceeding.

---

## Steps

### Step 1 — Verify source repo and fetch latest main

```bash
git -C <source_repo> fetch origin main
```

Check for errors. If the repo path doesn't exist, stop and report.

### Step 2 — Check target folder doesn't already exist

```bash
ls /Users/haimengzhou/apps/<folder_name> 2>/dev/null && echo EXISTS || echo OK
```

If EXISTS: stop and ask the user whether to use a different name or remove the existing folder.

### Step 3 — Create the worktree

```bash
git -C <source_repo> worktree add /Users/haimengzhou/apps/<folder_name> -b <branch_name> origin/main
```

Confirm the output shows `Preparing worktree` and `HEAD is now at`.

### Step 4 — Register in workspace.local.md

File: `/Users/haimengzhou/apps/ai-console/workspace.local.md`

Add a row immediately after the source repo's row:

```
| <folder_name> (worktree) | /Users/haimengzhou/apps/<folder_name> | <same tech as source repo> | active |
```

### Step 5 — Confirm

Report:
- Worktree path: `/Users/haimengzhou/apps/<folder_name>`
- Branch: `<branch_name>` tracking `origin/main`
- workspace.local.md updated: yes

---

## Teardown (when the ticket is merged)

To remove the worktree when done:

```bash
# From the source repo
git -C <source_repo> worktree remove /Users/haimengzhou/apps/<folder_name>
git -C <source_repo> branch -d <branch_name>
```

Then remove the row from `workspace.local.md`.

---

## Notes

- `git worktree add` creates the folder automatically — do NOT `mkdir` first.
- The worktree shares the `.git` object store with the source repo (no disk duplication of history).
- Each worktree can only have one branch checked out at a time.
- List active worktrees: `git -C <source_repo> worktree list`
