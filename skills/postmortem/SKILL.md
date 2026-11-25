---
name: postmortem
description: >
  Investigates a task-orchestrate task's failure or gap (a failed phase, an unmet acceptance
  criterion, a low-confidence completion, or a disputed verification) using grounded-investigate's
  dual-method pattern, then writes a structured root-cause report and persists it to the Obsidian
  wiki via wiki-ingest's page-creation conventions, and feeds actionable findings into
  `skill-improvement-backlog.md`. Use this skill when the user says "/postmortem <task-id>",
  "postmortem this task", "why did task X fail", "investigate this failed task",
  "write a postmortem for <ID>", "what went wrong with <task>", or when task-orchestrate's
  Completion step 6d detects a gap (✗ acceptance criteria, low/disputed confidence, verification
  failure) worth a deeper look than the Completion `Wiki:` line alone provides. Reuses
  grounded-investigate's Method A/Method B/cross-validate skeleton (dynamic evidence preferred over
  log-parsing when reproducible) and wiki-ingest's frontmatter/manifest/log.md conventions rather
  than inventing new mechanics — a postmortem about "what actually happened" should itself be held
  to the same evidence discipline it's investigating.
version: 1.0.0
investigation_model_tier: sonnet
---

# Postmortem — Task Failure & Gap Investigation

You are reconstructing what actually happened on a task-orchestrate task that failed, partially
failed, or completed with a gap (unmet acceptance criterion, low confidence, disputed
verification) — and turning that reconstruction into a structured, cross-validated report plus
actionable follow-ups. This is `grounded-investigate` applied to task-orchestrate's own execution
history: the same two-independent-methods discipline applies, and a postmortem that skips it (e.g.
reads one log and writes a conclusion) is exactly the failure mode this skill exists to prevent.

⚙️ **Model Tier:** Steps 2–4 (Method A, Method B, Cross-Validate) are investigation work and use
Sonnet, per the user's global model-tier policy (`~/.claude/CLAUDE.md`, "Premium Models for
Investigation & Planning") and mirroring `grounded-investigate`'s own inline tier note.
- **Claude Code:** dispatch Steps 2–4 with `Agent(model: "sonnet")`.
- **Cursor:** switch to Sonnet in Settings (⌘ + Shift + J) before running this skill; switch back
  after.

## Before You Start (wiki context)

Runs unconditionally, same as `grounded-investigate`'s "Before You Start" — skipping it because the
task file "looks self-explanatory" is the shortcut this discipline forbids.

1. Resolve `OBSIDIAN_VAULT_PATH` via the Config Resolution Protocol in `llm-wiki/SKILL.md`.
2. Read `$OBSIDIAN_VAULT_PATH/index.md` and `hot.md` — check whether a related postmortem already
   exists (same task, same root-cause pattern, same failing script/config). If one does, this run
   becomes an *update* to that page (Step 6), not a fresh page.
3. If no vault is configured, proceed without wiki grounding and note the gap explicitly in the
   final report and in Step 6 (never invent a vault path).

## Step 1 — Read the Task File and Locate Evidence

1. **Resolve the task ID** from the invocation (e.g. `/postmortem 20260628-inbox-A1DD [--phase N]
   [--reason "..."]`).
2. **Locate the task file**, in this order:
   - Active: `.orchestrate/tasks/{ID}.md`
   - Archived: glob `orchestrate-history/*-{ID}-*.md` (archived filenames are
     `{ARCHIVE_STAMP}-{ID}-{slug}.md` — the stamp prefix varies, the ID does not). If more than one
     file matches (a task re-run under the same ID), use the most recent stamp and note the
     ambiguity in Sources.
   - Neither found: stop and report "no task file found for {ID}" — do not fabricate one.
3. **Read the Goal, Context, and Acceptance Criteria** sections, and every embedded
   `## PHASE OUTPUT` block (or `## PHASE OUTPUT (Phase N)` for multi-phase tasks). Treat these
   blocks as the **authoritative** evidence source — not a fallback. `.orchestrate/logs/` sidecar
   files (`{ID}-phase{N}.log`, `{ID}-verify.log`) are best-effort supplementary evidence, written by
   `.orchestrate/bin/append-phase-log.sh` when that script exists; it does not exist in every
   checkout (confirmed absent in this repo as of 2026-08-09), so read the sidecar log **if present**
   but never block on its absence — say "sidecar log absent — using inline `## PHASE OUTPUT` only"
   rather than treating a missing `.log` file as a data gap in the investigation itself.
4. **Extract the gap** this postmortem is investigating: a phase's `status: ✗ failed`, an
   `acceptance_criteria_met` line with a `✗` entry, a phase `confidence: low`, or an explicit
   `--reason` passed on invocation. If `--phase N` was given, scope primarily to that phase's block
   but still read the whole file for context (a later phase's gap can originate in an earlier one).
5. **Classify the failure type** provisionally (refined in Step 4): `phase_failed` (execution error,
   non-zero exit), `blocker_external` (dependency/service/team outside this session's control),
   `blocker_internal` (project/environment/config issue), `acceptance_gap` (delivered but missed an
   AC), `verification_gap` (passed initially, a later check found an issue).

## Step 2 — Method A (prefer reproduction over reading old logs)

Mirrors `grounded-investigate` Step 2's actual discipline: Method A is dynamic evidence when
possible, not a second reading of stale artifacts.

1. **Check reproducibility.** Does the task file's `test_evidence` field, Context, or a referenced
   script/test name give you a concrete, narrowly-scoped command that caused the gap (a test file, a
   lint/build step, a script invocation)?
2. **If reproducible:** re-run it now, scoped as narrowly as possible (single test file/case, not
   the full suite), and capture fresh stdout/stderr. This is genuine Method A — dynamic evidence
   the original failure didn't have to prove itself twice.
3. **If not reproducible** (depended on external state, a one-time race, since-changed environment,
   or an ops/team dependency): fall back to log/`## PHASE OUTPUT` analysis, and say so explicitly in
   the report — `"not reproducible — falling back to static log analysis for Method A"` — exactly as
   `grounded-investigate` requires stating a substitution rather than silently downgrading.
4. **Either way**, parse whatever evidence you have for error patterns, stack traces, assertion
   failures, external-service errors, or (for the log-analysis fallback) the phase's own
   `confidence`/`blockers`/`test_evidence` prose.
5. **Record the finalized classification** from Step 1's provisional one, now backed by evidence.

## Step 3 — Method B (code/config review)

The second, genuinely independent method — reads code, not logs, so it draws on a different
evidence source than Method A regardless of which branch Method A took.

1. Read the actual file(s) implicated: the script/config/test that failed, or the implementation
   the acceptance criterion was measuring.
2. Reason from first principles: is the gap a code defect, a config error, an environmental issue,
   or a test/AC-definition gap (the AC itself was unmeasurable or ambiguous)?
3. Cross-reference the error against actual implementation vs. what the task file's Goal/Context
   describes as expected behavior. Check `git log`/`git blame` on the implicated file if the timeline
   matters (e.g. "was this already fixed by a later commit?").

## Step 4 — Cross-Validate

1. Write out Method A's finding and Method B's finding **side-by-side, explicitly**, before
   concluding anything — never synthesize first and backfill support.
2. **Agreement:** report the combined finding, citing both methods.
3. **Disagreement:** run **one** concrete tie-breaking check, in order of preference:
   1. re-run the failing command/test in isolation, if not already done in Step 2;
   2. `git log`/`git blame` on the implicated file(s) for a timeline mismatch;
   3. inspect an adjacent/sibling task's phase log or `orchestrate-history/` archive for the same
      symptom;
   4. verify the config/env actually applied at run time vs. what's on disk now (it may have since
      changed).
   - **Resolved:** report the resolved finding, and note the initial disagreement — that's useful
     signal, not to be discarded.
   - **Unresolved:** surface both findings under `## Disagreement`, citing both methods, stating
     what would resolve it. This is a `disputed` lifecycle state, not "low confidence" — see
     Confidence Mapping below.

**Confidence Mapping:**
- **high** — both methods agree, or disagreement was resolved by the tie-break.
- **medium** — one method inconclusive, or Method A had to fall back to log-analysis because
  reproduction wasn't feasible.
- **disputed** (not "low") — methods disagree and the tie-break didn't resolve it. `disputed` names
  two specific, conflicting, evidence-backed answers needing a human decision; "low" would
  misrepresent that as a single weak guess.

## Step 5 — Write the Report

```markdown
# Postmortem — <Task ID>: <one-line failure/gap summary>

## Failure Type
- **Category:** phase_failed | blocker_external | blocker_internal | acceptance_gap | verification_gap
- **Phase:** <phase name/number> or N/A (completion-level gap)
- **Acceptance Criteria:** <which AC was unmet, verbatim from the task file>

## Root Cause Analysis

### Method A: <Reproduction | Log Analysis (fallback — state why)>
- Finding: <what running/reading revealed>
- Evidence: <exact command run + output, or exact log/PHASE OUTPUT lines cited>

### Method B: Code/Config Review
- Finding: <what code inspection revealed>
- Evidence: <file path + line(s)>

### Agreement Assessment
✓ Both methods converge: <agreed root cause>
<!-- OR, if unresolved: -->
## Disagreement
Method A found <X>; Method B found <Y>. Tie-break attempted: <check> → <result>. Needs: <what would
resolve it>.

### Confidence
<high | medium | disputed>, with one line on why.

## Impact Analysis

### Phase Outcomes
- <Phase 1>: ✓ complete | ⚠️ partial | ✗ failed (reason)
- ...

### Acceptance Criteria Coverage
- ✓ AC-1: delivered
- ⚠️ AC-2: partial — <gap>
- ✗ AC-3: not delivered — <reason>

## Recommendations

### Process Improvements
1. <description> — impact: <expected outcome>, effort: low|medium|high

### Skill/Tool Improvements
1. <suggestion for grounded-investigate | task-breakdown | task-orchestrate | wiki-ingest | other>
   — category: acceptance_criteria | test_coverage | documentation | error_handling | skill_design

### Monitoring & Prevention
1. <alert or test that would catch this earlier> — severity: critical | high | medium

## Related Postmortems
- [[postmortems/<related-page>]] (if any surfaced in "Before You Start" or Step 6)

## Follow-Up Actions
- [ ] <actionable item, effort, impact>
- None
```

## Step 6 — Persist to Wiki

The report isn't done when it prints — persist it exactly the way `grounded-investigate` Step 6
persists an investigation, reusing wiki-ingest's page-creation conventions rather than inventing a
lighter-weight write.

1. **Decide if worth persisting**, reusing `grounded-investigate` Step 6's judgment: persist when
   the root cause is cross-validated (methods agreed or were reconciled) **or** when an unresolved
   `## Disagreement` was surfaced (a known-open question is worth recording). Skip only for a
   trivial, single-method, already-documented gap — and say so in one line rather than skipping
   silently.
2. **Check "Before You Start" for an existing related page first.** If one exists (same task,
   recurring root-cause pattern), append an `## Update — <ISO>` section instead of duplicating a
   page.
3. **Otherwise, prefer the existing wiki skills over hand-rolling a page**, in order:
   1. `wiki-capture` — best fit for a finished, self-contained finding.
   2. `wiki-ingest` raw-mode staging (`_raw/`) — when the finding should be promoted later rather
      than published immediately.
   3. Direct write into `$OBSIDIAN_VAULT_PATH/postmortems/{YYYY-MM-DD}-{task-id}-{slug}.md` — only
      if neither skill is reachable this session.
4. **Frontmatter** (required on every new page, per wiki-ingest's Quality Checklist — title,
   category, tags, sources — plus postmortem-specific fields):

```yaml
---
title: "Postmortem — <Task ID>: <failure summary>"
category: postmortems
tags: [postmortem, root_cause:<type>, improvement:<category>, ...]
created: <ISO timestamp>
updated: <ISO timestamp>
confidence: high | medium | disputed   # investigation's confidence in its root-cause finding
base_confidence: <0.0-1.0>             # wiki-ingest page-quality score: min(N/3,1.0)×0.5 + avg_quality×0.5 over sources
tier: supporting                       # core | supporting | peripheral; default supporting
lifecycle: draft | settled | disputed
lifecycle_changed: <ISO timestamp>
summary: "<one sentence, ≤200 chars>"
sources: [orchestrate-history/<task-file>, .orchestrate/tasks/<task-file>, .orchestrate/logs/<phase-log-if-present>]
provenance: {extracted: 0.X, inferred: 0.Y, ambiguous: 0.Z}
relationships:
  - target: "[[task-orchestrate/completion-workflow]]"
    type: uses
---
```

   `confidence` (investigation outcome) and `base_confidence` (page-quality score) are **distinct
   fields** — do not conflate them into one. `confidence` comes from Step 4's Confidence Mapping.
   `base_confidence` is computed per `llm-wiki/SKILL.md`'s formula regardless of what kind of page
   this is.

5. **Page body** = the Step 5 report rewritten as declarative knowledge (not a chat transcript):
   Failure Type, Root Cause Analysis (Method A/B + Agreement/Disagreement), Impact Analysis,
   Recommendations, Related Postmortems, Follow-Up Actions. Apply provenance markers per
   `llm-wiki/SKILL.md`: extracted claims unmarked, inferred claims get `^[inferred]`, ambiguous/
   contested claims get `^[ambiguous]`.

6. **Tag taxonomy:**
   - Always: `postmortem`
   - Root cause (exactly one): `root_cause:phase_failed` | `root_cause:external_blocker` |
     `root_cause:internal_blocker` | `root_cause:acceptance_gap` | `root_cause:verification_gap`
   - Improvement (one or more): `improvement:test_coverage` | `improvement:acceptance_criteria` |
     `improvement:documentation` | `improvement:error_handling` | `improvement:skill_design` |
     `improvement:monitoring`

7. **Whichever path was used, apply wiki-ingest's Step 7 checklist in full** — this is the part a
   lighter "just write hot.md" approach misses, and a page written without it is invisible to
   `wiki-dedup`'s manifest-based skip logic on a later ingest pass:
   - `.manifest.json` — add/update the source entry (`content_hash`, `pages_created`), bump
     `stats.total_pages`.
   - `index.md` — add the new page (or update the existing page's summary).
   - `log.md` — append `- [<ISO>] INGEST source="<task file>" pages_created=1 mode=append` (or
     reuse the `CAPTURE` line format `wiki-capture` itself uses, if that's the path taken).
   - `hot.md` — add to Recent Activity (last 3 max) if this is a recent/active investigation.
   - Cross-link to at least 2-3 existing related pages so the page isn't an orphan.
   - If `QMD_WIKI_COLLECTION` is set: run `qmd update` (and `qmd embed` if vectors are stale) after
     writing; record the refresh status in the final report. If unset or the CLI is unavailable,
     skip and say so — don't roll back the wiki write.

8. **Required output line (never silent):**
   ```
   Wiki: persisted to <page path> (<method: wiki-capture | wiki-ingest-raw | direct-write |
   existing-page-update>) | not persisted: <one-line reason>
   ```

## Step 7 — Feed the Skill-Improvement Backlog

For each actionable "Skill/Tool Improvements" recommendation from Step 5, append an entry to
**`skill-improvement-backlog.md`** at the ai-console project root (`/Users/haimengzhou/apps/
ai-console/skill-improvement-backlog.md` — not `.orchestrate/skill-improvement-backlog.md`; that
path doesn't exist in this repo, the real file lives at project root per `CLAUDE.md`'s own
"Skill-improvement backlog" reference).

Match the file's existing section format exactly (verified against its live content — do not
invent a new format):

```markdown
## <YYYYMMDD> — <task-id-or-slug>
- [<skill-name>] <recommendation description, one line, actionable>
  Source: <task file path>
```

Append under a new dated section if today's date has no existing section for this task; add as an
additional bullet under an existing same-day section otherwise.

**Shared Context accumulation:** if this postmortem's root-cause/improvement category matches
**≥2 prior postmortems** (check wiki `postmortems/` pages or the backlog file for the same
`root_cause:*`/`improvement:*` tag), append a note to `.orchestrate/project.md`'s Shared Context
section flagging the recurring pattern — e.g. "Three recent postmortems traced to
`improvement:acceptance_criteria` — recommend a task-breakdown AC-template enhancement." Skip this
for a single, non-recurring postmortem.

## Dispatch Mode

**Default: sequential, in one agent** — Step 1 → 2 → 3 → 4 → 5 → 6 → 7, same default as
`grounded-investigate` for the same reason (no dedicated multi-agent workflow tool to depend on;
degrade gracefully).

**Optional: parallel Agent-tool dispatch** for Steps 2–3 — when the `Agent` tool is available,
Method A and Method B MAY run as two independent subagents launched in the same message, each
genuinely blind to the other's findings until Step 4's comparison. Specify `model: "sonnet"` on
both dispatches (asymmetric tiers undermine independence, per `grounded-investigate`'s own note).

## What NOT to Do

- **Never treat an old failed run's logs as the only evidence when the failing command is
  re-runnable.** Re-run it — that's genuine Method A, not "two readings of stale artifacts wearing
  different labels."
- **Never fabricate task IDs, file paths, or line numbers as illustrative "examples" inside a real
  report.** A postmortem's entire value proposition is grounding claims in real evidence; treat any
  example content you write as load-bearing, not decorative — see this skill's own design plan
  (`ai-console/reports/cc-improvements/POSTMORTEM-inv_plan.md`, `## Challenge` finding 1) for what
  happens when that's violated.
- **Never collapse an unresolved disagreement into "confidence: low."** Use `disputed` and write the
  `## Disagreement` section — a bare low-confidence line reads as one weak answer, not two named,
  conflicting ones.
- **Never skip `.manifest.json`/`log.md` when writing a wiki page directly.** A page invisible to
  `wiki-dedup`'s manifest-based skip logic will get silently re-processed or missed by later ingest
  passes.
- **Never assume `.orchestrate/logs/{ID}-phase{N}.log` exists.** Check for it, use it if present, but
  the task file's inline `## PHASE OUTPUT` blocks are the authoritative source regardless.
- **Never invent a skill-improvement-backlog format.** Match `skill-improvement-backlog.md`'s
  existing section/bullet format exactly — a new format fragments the file's grep-ability.

## Reference

- `/Users/haimengzhou/.claude/skills/grounded-investigate/SKILL.md` — dual-method pattern (Steps
  2–4), disagreement handling, Step 6 persistence precedence.
- `wiki-ingest/SKILL.md` (Steps 5–7) — frontmatter fields, manifest/log.md/hot.md/index.md update
  mechanics, QMD refresh, Quality Checklist.
- `/Users/haimengzhou/.claude/skills/task-orchestrate/SKILL.md` — `## PHASE OUTPUT` block field
  names, Completion §6d (Direct Wiki Ingestion — the sibling mechanism this skill supplements with a
  deeper root-cause investigation for gaps that warrant one), `.orchestrate/tasks/{ID}.md` /
  `orchestrate-history/{ID}.md` file locations.
- `ai-console/reports/cc-improvements/POSTMORTEM-inv_plan.md` — this skill's design plan and
  adversarial Challenge review; consult for the reasoning behind the amendments folded in above
  (dynamic-preferred Method A, authoritative inline PHASE OUTPUT, confidence/base_confidence split,
  `disputed` lifecycle state, wiki-skill precedence order).
