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

### Step 0 — Resolve the canonical clone before anything else

**`~/apps` can contain more than one clone of the same remote, and the folder names do not tell you
which is current.** Picking the stale one gives you a worktree branched from a repo whose working
tree disagrees with `origin`, and whose docs may assert conclusions that have since been withdrawn.

Known case: `~/apps/dsp_stress_test` and `~/apps/ads_stress_test` are **both** clones of
`git@gitlab.cloudokyo.dev:haimeng.zhou/ads_stress_test.git`. `dsp_stress_test` is canonical;
`ads_stress_test` is a stale duplicate. See ai-console's `CLAUDE.md` → "Stress-test repo".

Before using `<source_repo>`, confirm it is the canonical clone:

```bash
# What remote does it track, and is it current?
git -C <source_repo> remote get-url origin
git -C <source_repo> fetch origin --quiet
git -C <source_repo> rev-list --left-right --count origin/main...HEAD   # want "0  0"
```

Then check no sibling **clone** shares that remote. Note the `-d "$d/.git"` test — a clone has a
`.git` *directory*, a worktree has a `.git` *file*. Without that test the scan flags every worktree
this skill creates, which is a false alarm:

```bash
for d in ~/apps/*/; do
  [ -d "$d/.git" ] || continue          # clones only; skip worktrees
  u=$(git -C "$d" remote get-url origin 2>/dev/null)
  [ -n "$u" ] && echo "$u  $d"
done | sort | awk '{c[$1]++; l[$1]=l[$1]"\n    "$2} END {for (r in c) if (c[r]>1) print "DUPLICATE CLONES of "r l[r]}'
```

As of 2026-09-13 this reports exactly one pair: `ads_stress_test` + `dsp_stress_test`. Every other
repo-looking folder under `~/apps` (`infra-6`, `p3-9b`, `ads-un1`, …) is a legitimate worktree.

If duplicates exist, use the one that reports `0  0` against `origin/main` and tell the user the
other is stale. **Do not create a new clone to get an isolated checkout — that is what produces this
problem.** A worktree shares the source repo's object store; that is the entire point of this skill.

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
- **A worktree is not a clone.** If you find yourself running `git clone` to get a second working
  copy of a repo already under `~/apps`, stop and use this skill instead. Duplicate clones drift
  silently: one gets fetched, the other doesn't, and months later two folders assert different
  conclusions from the same filenames.
- To check for existing duplicates at any time, run the Step 0 sibling-clone scan.
