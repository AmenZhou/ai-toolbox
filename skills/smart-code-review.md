---
name: smart-code-review
description: Ticket-aware code review. Fetches associated ticket/requirements (Linear, GitHub issue, PR description) and validates implementation against them. Falls back to a structured branch summary when no ticket is found. Always finishes with a standard BUG/FIX/AUTO/CONSIDER code review pass.
version: 1.0.0
inline: true
---

# Smart Code Review

Ticket-aware code review. Validates implementation against requirements when a ticket exists; summarizes the branch for manual verification when it doesn't. Always ends with a standard quality review pass.

---

## Phase 0 — Detect Ticket Context

Run these in parallel:

**A. Parse branch name**
```bash
git branch --show-current
```
Match against:
- `[A-Z]+-\d+` — Linear/Jira style (e.g. `INFRA-1`, `DSP-42`)
- `[a-z]+-\d+-` prefix slug (e.g. `infra-1-research-uat-infra` → `INFRA-1`)

**B. Check for open PR**
```bash
gh pr view --json title,body,url 2>/dev/null
```
Scan PR body for:
- Linear URLs: `linear.app/*/issue/*` or `linear.app/*/issues/*`
- GitHub issue refs: `#\d+` or `github.com/.*/issues/\d+`
- Explicit requirement sections: `## Requirements`, `## Acceptance Criteria`, `## AC`

**C. Collect branch diff metadata** (always needed)
```bash
git log main...HEAD --oneline
git diff main...HEAD --stat
```

**Decision:**
- Ticket/requirements found → **Phase 1a** (ticket validation)
- Nothing found → **Phase 1b** (branch summary)

If `gh` is unavailable or unauthenticated, skip B and go straight to Phase 1b.

---

## Phase 1a — Ticket Validation (ticket found)

**Fetch ticket content:**
- Linear URL in PR body → `WebFetch` the Linear issue URL
- GitHub issue ref → `gh issue view <number> --json title,body`
- Requirements block in PR body → use the PR body directly

**Get full diff:**
```bash
git diff main...HEAD
```

**Validate implementation vs. requirements:**

For each requirement / acceptance criterion:
- `✓` — addressed in diff (cite file/line)
- `✗` — not found in diff
- `?` — partially addressed or unclear

Also flag:
- Changes in diff that appear **out of scope** relative to the ticket
- Scope creep, unrelated refactors, or missing pieces

**Output:**
```
## Ticket Validation
Ticket: INFRA-1 — Document UAT infra topology
Source: https://linear.app/...

Requirements check:
  ✓ Topology diagram created — docs/infra_topology.md
  ✓ Phase 2 scaling plan — docs/infra_topology.md#scaling
  ✗ Load balancer config documented — not found in diff
  ? Namespace / resource limits — partially addressed (no limits table)

Out of scope: none detected
```

Then proceed to **Phase 2**.

---

## Phase 1b — Branch Summary (no ticket found)

Collect and present a structured summary for manual verification:

```bash
git log main...HEAD --oneline          # commit history
git diff main...HEAD --stat            # changed files + line counts
git diff main...HEAD                   # full diff (summarize by area)
```

**Output:**
```
## Branch Summary
Branch: infra-1-research-uat-infra
Base: main | Commits: 4 | Files changed: 6 (+312 / -18)

Commits:
  975fde4 fix(infra): address P0 and P1 review comments
  f3c7ef2 docs(infra): fix issues 1-4 + add phase_a_blockers.md
  cc7a8d7 chore: untrack uat3-ads.yaml (credentials)
  656144f docs(infra): INFRA-1 — document UAT infra topology

Changes by area:
  docs/           infra_topology.md (+280/-10), phase_a_blockers.md (+32)
  .gitignore      uat3-ads.yaml untracked (+2)

Summary:
  - Added UAT infrastructure topology documentation
  - Documented Phase A blockers
  - Removed credentials file from tracking

No ticket found — please verify the above matches your intended scope.
```

Then proceed to **Phase 2**.

---

## Phase 1c — Changelog Check (always runs after Phase 1a or 1b)

Check whether the branch includes an update to `CHANGELOG.md`:

```bash
git diff main...HEAD --name-only | grep -i changelog
```

- **Found** → confirm the entry covers the ticket/feature being merged. Report `✓ CHANGELOG.md updated`.
- **Not found** → report as a `[FIX]` item: `CHANGELOG.md not updated — add an entry for this ticket before merging`.

Do not auto-fix. Adding a changelog entry requires judgment about what to write.

---

## Phase 2 — Code Quality Review (always runs)

Apply standard review categories to all changed files:

| Category | What | Action |
|----------|------|--------|
| **[BUG]** | Logic errors, security, data loss, race conditions | Report → wait |
| **[FIX]** | Type gaps, missing error handling, test gaps | Report → wait |
| **[AUTO]** | Unused imports, dead code, console.log, typos | Fix immediately |
| **[CONSIDER]** | Refactors, style opinions, nice-to-have | Mention only |

### AUTO criteria (all must be true)
- Zero risk of breaking behavior
- < 5 seconds to fix
- No judgment call needed

**Process each changed file:**
1. Read the diff for the file
2. Categorize findings
3. Auto-fix `[AUTO]` items immediately
4. Collect `[BUG]`/`[FIX]`/`[CONSIDER]` items

**Standard checks:**
- Can this be simpler? Unnecessary abstraction, over-engineered error handling?
- Dead code, unused exports, commented-out blocks?
- Copy-paste that should be extracted (but avoid premature abstraction)?
- Security: injection, XSS, exposed secrets, missing auth?
- Missing tests for new logic?

---

## Final Output

```
## Code Review
Total: BUG: X | FIX: X | CONSIDER: X  (auto-fixed: Y)

Issues:
1. [BUG] <description> — `path/to/file:line`
2. [FIX] <description> — `path/to/file:line`
3. [CONSIDER] <description> — `path/to/file:line`

What to fix?
  a) BUG + FIX [recommended]
  b) BUG only
  c) All including CONSIDER
  d) Custom (e.g. "1,3")

I'll assume a) if you don't specify.
```

**STOP. Wait for user selection before applying any BUG/FIX changes.**

---

## Error Handling

| Situation | Response |
|-----------|----------|
| `gh` not installed / unauthenticated | Skip PR lookup, proceed to Phase 1b |
| Linear URL requires login | Note "Linear requires auth — paste ticket text to validate" |
| No commits ahead of main | "Branch is up to date with main — nothing to review" |
| Binary or generated files | Skip, note in summary |
| Large diff (> 500 lines) | Process in batches by file area |
