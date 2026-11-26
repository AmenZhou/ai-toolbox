---
name: task-breakdown
description: Turn a job (spec, plan doc, rough notes, or the current conversation) into the SMALLEST safe task-orchestrate plan — one `.orchestrate/tasks/{ID}.md` file of right-sized units, most of them a single phase — so a later task-orchestrate run executes the whole job. Use when the user says "break this down into a task plan", "turn this spec into a task-orchestrate plan", "decompose this job for orchestrate to execute", "plan and orchestrate this", or "split this work into phases for /orch". This is the multi-unit decomposer + task-plan writer. Investigation, Challenge and Verify phases are added only where a unit's risk or unknowns earn them, because task-orchestrate already critiques every phase and reviews the finished task. Never starts execution — writes the plan and stops at the orchestrate go-gate.
version: 4.0.0
investigation_model_tier: sonnet
decomposition_model_tier: sonnet
---

# task-breakdown

Decompose a job into right-sized units and write them as **one task-orchestrate task file**
(`/Users/haimengzhou/apps/ai-console/.orchestrate/tasks/{ID}.md`). A later `/orch resume` → pick the
ID → "go" runs it. Run this skill on Sonnet (`Agent(model: "sonnet")` in Claude Code): unit
boundaries and dependencies are the part worth the premium model.

**HARD RULE:** this skill NEVER starts execution. It writes the task file, registers the row in
`project.md` as `awaiting_go`, and stops. task-orchestrate always needs an explicit "go". (Plans are
one task file, not inbox tickets: the async inbox/tend infrastructure was archived 2026-08-06, so
execution is manual and immediate.)

**Scope:** this skill splits a job into units; it does not write a unit's own description in depth.

## The principle: pay for a phase only when it removes a real risk

Every phase is an agent dispatch plus a critic pass. A plan that wraps each unit in
investigate → challenge → implement → verify multiplies cost and repeats the same checks, and the
runtime already supplies two of them for free:

- task-orchestrate's **critic** grades every phase against its `acceptance_criteria` and runs the
  build/lint/tests when files changed.
- At Completion it dispatches a fresh-context **independent review** of the whole diff against the
  task's Acceptance Criteria and Out of Scope list, and the plan's final `Test & Verify` phase checks
  the job as a whole.

So a unit defaults to **one phase** — `<ID>-IMPL`, with its approach in Design and its check in Test
Plan. Add siblings only for these reasons:

| Add | Only when | Why it earns its cost |
|-----|-----------|-----------------------|
| `<ID>-INV` (read-only, writes a plan artifact) | The approach depends on something not yet known that must be read or measured (a count, an unfamiliar subsystem, a choice between designs). If the job text already fixes the approach, skip it. | IMPL can't be specified without the answer. |
| `<ID>-CHALLENGE` (fresh-context refutation of the INV plan) | An INV plan exists and being wrong is costly: gated/irreversible/shared-infra work, or INV chose between materially different designs. A gated IMPL with a known fix needs none; its review-script checkpoint is the check. | An adversarial second look is cheap next to a bad mutation. Amends the plan artifact for a fixable gap; fails ❌ into task-orchestrate's `needs_human` if the gap needs a human; never a second ask-flow. |
| `<ID>-VERIFY` | The result lives outside the diff and the critic can't see it (live system state, a deploy, data in a DB). | Fresh eyes on state, not code. Code-only units rely on the critic + Completion review. |

Two units that share files or one Test Plan are one unit. If the plan exceeds ~12 phases, merge
units or drop a sibling before presenting it. Never write a Challenge or Verify phase just because
the unit "feels important".

## Step 1 — Read the job, check overlap, pull wiki context (once)

1. **Read the source fully** (path, pasted doc, notes, or the whole conversation). Note target
   repos/paths, counts, CLI interfaces, naming conventions, anything that affects gating or order.
2. **Overlap check, one pass.** Read the `## Task Registry` in `.orchestrate/project.md`; for rows
   with status `pending|running|awaiting_go|needs_human`, flag any whose ID/summary the job names, or
   whose `**Target:**` matches this job's target repo+branch. Hits become a warning in `## Context`
   and in Step 6's printout. They are never a `depends_on:` — nothing enforces a cross-task gate at
   dispatch, so the human reviewing the plan is the enforcement.
3. **Wiki context, one call:** `/wiki-context-pack "<job title/goal>" --budget 1500`. Skip for
   wiki-maintenance jobs; if it errors write `(unavailable — proceeded without it)`. Use it to spot
   a *real* conflict with a recorded decision (then ask, below) and to reuse existing conventions —
   a coincidental topic overlap is not a conflict.

**Ask only what research can't answer.** Most unknowns belong in a unit's INV phase. Stop and ask
the human, with options and your recommendation, only when the answer needs a product/business
judgment, access the agent lacks, or a hard-to-reverse design choice. Keep decomposing the units the
question doesn't block, then wait.

## Step 2 — Decompose into units

- One unit = what one agent can finish in one focused phase. **Split** when a unit would need more
  than ~5 acceptance criteria or spans subsystems/repos; **merge** trivially-coupled fragments.
- Give each a work-area ID (`DS-1`, `INFRA-2`) and a short title.
- Choose its shape from the table above; the default is `IMPL` alone.
- Draw cross-unit `depends_on:` from real data/artifact flow, pointing at the **specific phase** that produces the dependency (an `-IMPL`, not automatically the upstream `-VERIFY`). Break any cycle by merging or re-splitting.
- Number phases in wave order (no-dependency phases first); task-orchestrate dispatches by `depends_on:`.

## Step 3 — Write each phase

```markdown
### Phase N: <ID>-<STAGE> — <short title> [executor · type]
status: pending
depends_on: <phase number(s) or none>
acceptance_criteria:
- Specific, measurable, checkable by someone other than the author; scoped to this phase

**Target:** <repo path / branch / cluster, if any>

**Description** — what and why, with the counts, interfaces and constraints the executor needs.
Self-contained; an IMPL after an INV points at the INV artifact instead of restating it.

**Design** — approach in a few lines (INV: where to look and what the plan artifact must contain).

**Test Plan** — exact commands/queries with expected values (`SELECT count(*) = 12`, not "check it").
```

Add **Out of Scope** or **Open Questions** to a phase only when they carry real content (a
tempting-but-forbidden file, a genuine unresolved question). Do not write "None." boilerplate.
Job-wide prohibitions go once in the task file's `## Out of Scope`, which the Completion review
reads. Add an **Implementation Plan** list only when step order is non-obvious.

AC hygiene (these save reruns): derive any count AC from enumerated artifacts
(`existing + new == asserted`), never from memory; for "0 failures" ACs exclude tests that need
live local state (running service, installed binary, network/DB) or say so in the AC.

Executor/tier: INV and CHALLENGE are `agent/Sonnet` (`general-purpose` with `model: "sonnet"`; never
the Haiku-pinned `scout` or `Explore`). IMPL is `agent/executor` for 3+ files or iteration where the
agent makes design choices, `agent/mech-executor` when the phase is fully specified and mechanical
(renames, bulk edits from an explicit spec, tests that follow an existing convention), and
`inline · execution` for ≤2 files with a clear spec. VERIFY and the final phase are
`inline · execution`. Write the cell the same way every time: `[agent/executor · execution]`,
`[agent/mech-executor · execution]`, `[agent/Sonnet · investigation]` or `[inline · execution]`.
Name an Opus role (`verifier`, `security-reviewer`, `security-executor`) only when the plan wants it
for a high-stakes phase, and say why in that phase's Description: they matched a generic agent on
quality in a measured test and cost 1.5x to 1.7x as much (`security-reviewer` was the exception).

## Step 4 — Gating

`mode: auto` by default. `mode: gated` only if some Implementation phase *performs* a destructive
op (`rm -rf`, `DROP`/`DELETE`/`TRUNCATE`, force-push), a Kubernetes/helm mutation, an email/Slack
post, a deploy, or the user asked for gating. A phase that merely mentions a risky op doesn't count.
Gated means a pause at every checkpoint, so gate only on real work. A gated IMPL stops at a review
artifact (write the mutating command to `~/apps/ai-console/tmp/kube-cmd-*.sh`; `/tmp` is blocked
here) and does not run the risky step.

## Step 5 — Write the task file and register it

`{ID}` = `YYYYMMDD-HHMMSS` UTC at writing time. Registration is a plain file edit: append
`| {ID} | <summary> | <mode> | 1 | awaiting_go | <same UTC timestamp> |` to the `## Task Registry` table
in `.orchestrate/project.md`, matching the existing columns exactly. No helper scripts exist; do not
invent one.

```markdown
id: {ID}
task: <one-line title>
mode: auto | gated
total_phases: <count, including the final phase>
source: task-breakdown

## Goal
<1–3 sentences: what is true when the whole job is done>

## Context
<constraints, target repos, relations between units, and any Step 1 overlap warning>

## Acceptance Criteria
- <job-level done-statements; each must be covered by some phase's own criteria>

## Out of Scope
- <job-wide prohibitions, or omit the section>

## Wiki Context
<verbatim pack from Step 1, or "(unavailable — proceeded without it)">

---

## PHASES
<phases from Step 3>

### Phase N: Test & Verify [inline · execution]
status: pending
depends_on: <every unit's last phase>
acceptance_criteria:
- All output files declared across phases exist; the detected test suite passes (or "no test runner detected")
- No `files_changed` path outside the declared scope
```

The final `Test & Verify` phase is mandatory (task-orchestrate's Plan Presentation rule). It is the
single job-level check; do not add a second aggregate.

**Coverage check before presenting:** every top-level Acceptance Criterion maps to at least one
phase's own criteria, and the Goal is reachable from the phases together. Fix gaps by adjusting a
phase now; if closing a gap needs a human decision, ask (Step 1).

## Step 6 — Present, then STOP at the go-gate

Print a compact table (phase, stage, title, executor, depends on), the overlap warning if any, and
a one-line recommended next step. Then print exactly:

```
Task plan {ID} written to .orchestrate/tasks/{ID}.md and registered in project.md — status:
awaiting_go. Nothing has been executed. Run `/orch resume`, pick {ID}, then "go" or "go auto" to
execute it — that runs immediately, in that session (no background dispatch in this project).
(Optional: type "grill" to pressure-test the plan with an interview first.)
```

"grill" runs the `grilling` skill on the plan with the human present; never invoke it unprompted
(it waits on a human). If the interview changes the plan, edit the file, reprint the table, and
return to this gate. Do not run any phase or flip the row to `running`; the human owns the go.

## Example — a three-unit job, 6 phases (not 13)

Job: "Seed MCC fixtures, restart the broken redis-proxy, then run the unit-cost ramp."

| Phase | Stage | Why this shape |
|-------|-------|----------------|
| 1 | DS-1-INV | Fixture count/persona mix isn't stated; must be read from the spec and config |
| 2 | DS-1-IMPL | Executes the INV plan; Test Plan re-runs the seed (`0 inserted`) and the count query |
| 3 | P3-9-IMPL | Fix is known; the restart is gated (`kubectl rollout restart`), so the command goes to a review script |
| 4 | P3-9-VERIFY | The result is live cluster state the diff can't show: confirm a master is elected |
| 5 | P3-3-IMPL | The ramp spec is complete; depends on 2 and 4 |
| 6 | Test & Verify | depends on 2, 4, 5 |

`mode: gated` because phase 3 mutates the cluster. DS-1 got an INV because of a real unknown, P3-9 a
VERIFY because its outcome is not in any file, P3-3 neither. The old four-phase-everywhere shape
would have produced 13 phases for the same job.
