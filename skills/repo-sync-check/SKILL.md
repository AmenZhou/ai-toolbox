---
name: repo-sync-check
description: Check whether a local git repo is ahead of, behind, or diverged from its origin
  remote, and fast-forward-reconcile it (push if ahead-only, pull --ff-only if behind-only).
  Defaults to ~/apps/linecook if no --repo is given. Use for "/repo-sync-check", "is linecook
  outdated", "check if my repo is behind origin", "is my repo in sync with origin", or "sync
  <repo> with its remote". Never auto-merges or force-pushes — a diverged repo (both ahead and
  behind) is always reported to the human, not resolved automatically.
inline: true
---

# /repo-sync-check

**Argument:** `--repo <path>` — path to the local git repo to check. Default: `~/apps/linecook`.

Run, substituting `$REPO` with the given/default path:

```bash
cd "$REPO"
git fetch --all
git status --short                           # confirm working tree is clean before touching anything
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
COUNTS="$(git rev-list --left-right --count "HEAD...@{u}")"
AHEAD="$(echo "$COUNTS" | cut -f1)"
BEHIND="$(echo "$COUNTS" | cut -f2)"
```

If `git status --short` printed any output, stop and report that the working tree is dirty —
do not push or pull. A dirty tree makes even an ahead-only or behind-only case unsafe to act on.

Otherwise, act on `$AHEAD`/`$BEHIND`:

| AHEAD | BEHIND | Case | Action |
|-------|--------|------|--------|
| 0 | 0 | in sync | Report "up to date", no action needed. |
| >0 | 0 | ahead-only | `git push origin "$BRANCH"` |
| 0 | >0 | behind-only | `git pull --ff-only origin "$BRANCH"` |
| >0 | >0 | **diverged** | **Do NOT act.** Report both counts, the branch, and that this needs manual reconciliation. |

After running push or pull, re-run the `git rev-list --left-right --count HEAD...@{u}` check once
to confirm `0	0` and report the final state.

## Safety rules

- **Fast-forward only.** The only two mutating commands this skill ever runs are `git push origin
  <branch>` (ahead-only case) and `git pull --ff-only origin <branch>` (behind-only case).
- **Never `--force` / `--force-with-lease` / `-f`.**
- **Never `git rebase`**, and never a merge that could produce a merge commit or conflict
  resolution.
- **Diverged history (ahead > 0 AND behind > 0) is always reported to the human, never
  auto-merged.** Resolving a real divergence (merge, rebase, or choosing a side) is a human
  decision, not something this skill guesses at.
