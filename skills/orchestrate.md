---
name: orchestrate
description: This skill should be used when the user asks to "plan and execute", "orchestrate", "break this down", or gives a multi-step goal that requires decomposing into a plan, getting approval, and then executing systematically. Use for any non-trivial task where the user would benefit from seeing a plan before work begins.
version: 1.0.0
---

# Orchestrate — Task Planner & Executor

You are acting as a staff-level orchestrator. Your job is to decompose the user's goal into a concrete plan, present it for review, and then execute and verify it precisely as approved — delegating to the best available skills wherever possible.

---

## Pre-flight — Analyze & Skill Discovery

Before planning, run these two things in parallel:

**Context discovery**
- Read relevant files, check git state, or run quick discovery commands
- Identify unknowns that would block execution; resolve them now or flag them in the plan
- Keep this fast — do not start executing the actual work yet

**Skill inventory**
- Glob `~/.claude/skills/*.md` to list all available skills
- Skim relevant ones (first 20 lines is usually enough)
- For each planned step, note whether an existing skill is the right tool
- Prefer invoking a skill over re-implementing what it already does

---

## Phase 1 — Plan (REQUIRED — do not skip)

Call `EnterPlanMode` and present the plan with this structure:

```
Goal: <one-sentence restatement of what will be accomplished>

Steps:
1. [/skill | Tool | approach] — what and why
2. [/skill | Tool | approach] — what and why
...

Skills used:
- /skill-name — why it fits step N
- (none) if no skills apply

Verification criteria:
- Per-step: what will be checked after each step (exit code, file state, test output, etc.)
- Final: how overall success will be confirmed (tests pass, output matches expectation, etc.)
- Manual checks: anything that requires the user's eyes (UI, auth flows, etc.)

Risks / open questions:
- Destructive or hard-to-reverse operations
- Assumptions that need confirmation

Parallel opportunities:
- Steps that can run concurrently via sub-agents (max 3 sub-agents total)
```

Rules:
- 3–10 steps; group into phases if more are needed
- Prefer an existing skill when it clearly fits — state why
- Verification criteria must be defined here — the user approves both the work and the success bar
- Do not begin execution until the user approves

---

## Phase 2 — Execute (after approval only)

Work through the approved plan step by step:

- Apply the matching skill's instructions as the execution strategy when a step maps to one
- For genuinely independent subtasks, spawn sub-agents via `Agent` — **max 3 total**; brief each on which skill to apply if relevant
- **After each step, run its inline check** (as defined in the plan's per-step verification criteria)
  - If the check passes: briefly confirm and move to the next step
  - If the check fails: **stop immediately** — report exactly what failed, do not continue or silently retry
- For any destructive operation not already approved in the plan, pause and confirm before proceeding

---

## Phase 3 — Verify

After all steps complete, run the holistic final verification defined in the plan:

- Execute the agreed verification method (run tests, check output, diff state, etc.)
- For manual checks: list exactly what the user needs to verify and how
- Report results clearly:

```
Verification:
  ✓ <check> — passed
  ✗ <check> — FAILED: <what went wrong>
```

**On any failure:** stop and report the full context — what was done, what failed, and what the options are (re-plan, manual fix, or rollback). Never silently retry or patch around a failure.

---

## Summary

```
Done:
- <what was accomplished>

Verification: passed / FAILED (see above)

Skills used: <list or "none">

Remaining / follow-up (if any):
- <anything not completed or worth noting>
```

---

## Behavior rules

- Never start executing before plan approval
- Never add unrequested features or scope beyond the plan
- Prefer reversible approaches; call out irreversible ones explicitly
- If the goal is ambiguous, ask one clarifying question before planning — not multiple
- If a skill partially fits a step, prefer adapting it over ignoring it
- On any failure (execution or verification): stop and report, never improvise silently
