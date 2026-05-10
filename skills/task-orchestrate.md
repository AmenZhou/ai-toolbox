---
name: task-orchestrate
description: Use when you need to break a complex task into phases, approve each step, and route each phase to the right executor — running simple/narrow phases inline and delegating only genuinely complex or parallel work to agents.
---

You are the **orchestrator**: you plan, approve, and execute — running phases inline with your own tools when that's efficient, spawning agents only when truly needed.

**Spawn an agent only when:**
1. A phase is too large to fit in the main context (~10+ tool calls or 3+ files to create/rewrite)
2. Genuine parallelism is needed (inline phases cannot run in parallel)
3. A skill's embedded instructions make isolation valuable

For everything else, run inline.

---

## Permission Check (runs before anything else)

Read `.claude/settings.json` (project) and `~/.claude/settings.json` (global). Check for these in any `permissions.allow` list:
- `Bash(mv:*)`, `Bash(rm:*)`, `Bash(git push:*)`

**All present:** proceed silently.

**Any missing:** surface once before presenting the plan:

```
⚠ Auto mode may be interrupted — missing permissions: <list>

To grant:
  Claude Code — add to .claude/settings.json: {"permissions": {"allow": [...]}}
  Cursor / Windsurf — enable "Auto-run" / "Yolo mode"
  Gemini CLI — add to ~/.gemini/settings.json under permissions.allow

Type "grant" (project settings) · "grant global" (global settings) · "skip" (continue without)
```

On **"grant"** / **"grant global"**: read the settings file (create if absent). Validate that `permissions.allow` is an array — if `permissions` key is absent, create it; if `allow` is not an array, surface an error and do not write. Merge missing entries, write back, confirm `✓ Permissions updated`, proceed to plan.

---

## State File & Resume

**New task path** (a task description was given, or first invocation with no state file):
- Generate a collision-resistant ID: `YYYYMMDD-HHMMSS` from current datetime. Check no `.task-orchestrate-state-{ID}.md` exists in CWD; if collision, append `-2`, `-3`, …
- Use that ID as `{N}` for this session, then proceed to Phase Classification.

**Resume path** (`resume` keyword alone, or no task given):
- Scan CWD for `.task-orchestrate-state-*.md`
- None found → ask "What task would you like to orchestrate?"
- One or more found → list `[ID] <task> — phase X/Y (<status>)`. State files with `mode: pending` older than 7 days are abandoned — list separately, offer "delete abandoned? (y/n)". **Always wait for user to pick an ID** — never auto-load.
- On resume: restore `mode` from state file. If `mode: pending`, re-present phase list and wait for go/go-auto/abort (skip pre-execution questions). If `mode: auto`, continue executing immediately.
- **`awaiting_critic` on resume:** check `captured_output` in state file. If present: announce `▶ Phase N — agent returned before compression, resuming from captured output`. Skip the pre-critic state write in Step A (status is already `awaiting_critic` and `captured_output` is already on disk) — go directly to the inline assessment using the stored fields. Do NOT re-invoke the phase. If `captured_output` is absent: reset status to `pending`, increment retries, re-invoke.

**`resume` must be the full input.** Any input with other words is a new task.

---

## Phase Classification

Classify task complexity: **Lightweight** (2–3) · **Moderate** (4–5) · **Complex** (6). Consolidate before presenting: merge consecutive phases of the same type/executor with no dependency; cap at 6 phases.

### Step 1 — Phase type

| Keywords | Type |
|---|---|
| research, analyze, plan, design, document | instructional |
| implement, build, write code, fix, create, test, verify | execution |
| review, architect, assess, evaluate | reasoning |
| fetch, lookup, list, run, query, git | simple |

Precedence: reasoning > execution > simple > instructional.

### Step 2 — Executor

| Condition | Executor |
|---|---|
| simple or instructional phase | **inline** |
| execution — narrow (≤2 files, clear spec, ≤5 tool calls estimated) | **inline** |
| skill phase where skill declares `inline: true` | **inline · /skill-name** |
| execution — moderate or broad (3+ files, iterative, design judgment) | **agent/Sonnet** |
| reasoning phase | **agent/Sonnet** |
| any phase that must run in parallel with another | **agent/*** (inline can't parallelize) |
| skill phase where skill does NOT declare `inline: true` | **agent/** at appropriate tier |

**inline** = orchestrator runs the phase directly (Read, Edit, Write, Bash, etc.) — no Agent tool call.

**Inline skill invocation:** When a phase uses a skill, read `~/.claude/skills/<name>/SKILL.md` and check its frontmatter for `inline: true`. If present: the orchestrator follows the skill's instructions step-by-step using its own tools — no agent spawned. Label the phase `[inline · /skill-name]`. If `inline: true` is absent: embed the skill body into an agent prompt (standard path).

Inline is preferred. Default to it unless one of the agent conditions is clearly met.

### Step 3 — Derive per phase

- **`depends_on`**: phase numbers that must complete first. Phases with no shared output and no logical dependency can run in parallel.
- **`acceptance_criteria`**: 2–3 "done" statements for execution and reasoning phases. Omit for simple/instructional.

---

## Plan Presentation

```
TASK PLAN — `<summary>`  Complexity: Lightweight|Moderate|Complex (N phases)
Phase 1: `<name>` [inline · simple] → `<output>`
Phase 2: `<name>` [inline · execution] → `<output>`
Phase 3: `<name>` [/skill-name · agent/Sonnet] [parallel with 4] → `<output>`
Phase 4: `<name>` [agent/Sonnet] [parallel with 3] → `<output>`
```

Immediately after the plan, surface pre-execution questions (skip any that are obvious from context):

```
❓ Before we start:
1. <biggest risk or ambiguity>
2. <scope or assumption — omit if clear>
3. <dependency or side-effect — omit if clear>

⚠ MCP services involved: <list>   ← omit if none
  "go auto, approve MCP: <services>" to pre-authorize
  "go auto" alone keeps per-MCP gates

Answer inline, then: "go" (gated) · "go auto" (ungated) · describe changes · "abort"
```

If no questions and no MCP: `▶ Plan looks clear — type "go" or "go auto" to proceed.`

**Write state file** to CWD:

```
id: "{N}"
task: "<summary>"
complexity: Lightweight|Moderate|Complex
mode: pending
total_phases: N
mcp_preauthorized: []
phases:
  1: [inline · simple]         pending  depends_on: []  retries: 0  criteria: []
  2: [inline · execution]      pending  depends_on: [1] retries: 0  criteria: ["...", "..."]
  3: [agent/Sonnet]            pending  depends_on: [2] retries: 0  criteria: ["..."]

# OPERATING RULES
# Re-read ~/.claude/skills/task-orchestrate/SKILL.md before each turn (skip only if just invoked).
# Inline phases: orchestrator executes directly with its own tools — no Agent call.
# Agent phases: spawn Agent tool only for complex/parallel/context-heavy phases.
# Critic and micro-verifier always run inline (no separate agent).
# State file ID is datetime-based (YYYYMMDD-HHMMSS).
# Resume: always list files and wait for user pick — never auto-load.
# Phase statuses: pending → in_progress → awaiting_critic → ✓ complete / ✗ failed.
# Write awaiting_critic + captured_output before running critic.
# CHECKPOINT RULE (canonical): write ✓ complete to state file immediately after each phase PASS — never batch-update. See "Inline phase execution" section for full enforcement rules.
# Auto mode: after ✅ immediately scan for next ready phases — no pause, no prompt.
# Rabbit hole: halt after 4 retries (3 for Sonnet-tier), replan.
# Completion: archive state file to ~/apps/ai-console/orchestrate-history/ BEFORE deleting it. See Completion section for full steps.
```

---

## On "go" / "go auto"

Update state file `mode` immediately:
- `"go"` → `mode: gated`
- `"go auto"` → `mode: auto`
- `"go auto, approve MCP: <list>"` → `mode: auto`, `mcp_preauthorized: [<list>]`
- Free-form input → treat as plan revision, re-present, re-prompt.

---

## Execution Loop

**Self-refresh at start of each turn:** re-read this skill file and the state file. Skip only if this is the first turn after the Skill tool was just invoked.

**Ready phases** = all `depends_on` entries are `✓ complete` AND status is `pending`.

### Inline phase execution

Run the phase directly using your own tools. When done, produce a PHASE OUTPUT block:

```
## PHASE OUTPUT
files_changed: [list or "none"]
summary: <one sentence>
confidence: high | medium | low
blockers: [list or "none"]
```

Then evaluate it yourself against the acceptance criteria (no critic agent). Assign: **PASS** · **PARTIAL: \<gap\>** · **FAIL: \<reason\>**.

If `files_changed` is non-empty, run a quick inline sanity check (Bash lint/build/test commands). If that fails, downgrade to PARTIAL.

**State file write is mandatory after every inline phase** (CHECKPOINT RULE — canonical here) — follow Steps A/B/C immediately. Never defer or batch. The OPERATING RULES in the state file carry a summary of this same constraint; if they ever conflict, this section governs.

**Inline skill invocation:** For `[inline · /skill-name]` phases, Read the skill's SKILL.md, then follow its instructions directly — executing each step yourself using your own tools. Do not spawn an agent. Announce `▶ Phase N — <name> (inline)` before starting.

### Agent phase execution

**Before invoking:** announce `▶ Phase N — <name>`.

**Agent prompt must include:**
1. Prior phase summaries as context
2. Absolute working directory
3. Acceptance criteria: "This phase is complete when: 1. … 2. … 3. …"
4. Required output: "End your response with a `## PHASE OUTPUT` block: files_changed / summary / confidence / blockers"
5. If a skill is embedded (skill did NOT declare `inline: true`): paste the relevant SKILL.md body directly — do NOT invoke Skill tool from within agent

**Parallel phases:** launch as multiple Agent tool calls in a single message (max 6). Announce `▶ Phases N, M (parallel)`. Wait for all to return before assessing.

**Foreground vs background:** default to foreground. Use `run_in_background: true` only when > 5 min expected AND there is other independent work to run concurrently.

After the agent returns, extract the `## PHASE OUTPUT` block. If missing: treat as ⚠️ with gap "no PHASE OUTPUT block" — do not invoke critic.

### Critic & micro-verifier (always inline)

For execution and reasoning phases (both inline and agent), assess the PHASE OUTPUT against acceptance criteria:
- **PASS** — all criteria met
- **PARTIAL: \<gap\>** — most criteria met, one gap
- **FAIL: \<reason\>** — key criterion not met or blocker caused by this change

If `files_changed` is non-empty, run Bash to verify (build, lint, fast tests). Override to PARTIAL if verification fails.

Classify any blockers as `pre-existing` or `caused-by-change`. Pre-existing blockers do not downgrade a PASS verdict — surface them as notes instead.

Skip assessment for simple and instructional phases.

---

## Feedback → Decision → Execute (Steps A/B/C)

**Step A — Capture:**
Write to state file immediately after phase completes (before assessment):
```
phase N status → awaiting_critic
phase N captured_output → {summary, confidence, files_changed, blockers}
```

**Step B — Verdict table:**

| Assessment | Confidence | Blockers | Verdict |
|---|---|---|---|
| PASS | high or medium | none | ✅ |
| PASS | low | none | ⚠️ "low confidence" |
| PASS | any | pre-existing only | ✅ with note |
| PASS/PARTIAL | any | caused-by-change | ❌ first blocker |
| PARTIAL | any | any | ⚠️ critic's gap |
| FAIL | any | any | ❌ critic's reason |
| (block missing) | — | — | ⚠️ "no PHASE OUTPUT block" |

For simple/instructional (no assessment): high/medium confidence → ✅, low → ⚠️.

**Step C — Act:**

- **✅** → write checkpoint (`✓ complete`, copy summary). Reset retries to 0.
  - **Gated**: output 2–3 line summary, `⏸ Ready for Phase N+1 — "go" · changes · "skip" · "abort"`
  - **Auto**: output `✓ Phase N — <summary>`, immediately execute next ready phase(s)

- **⚠️** → increment retries. Output `🔍 Gap: <what's missing>`. Re-invoke phase with gap appended.
  - Inline → just retry the inline steps with the gap context
  - Agent → re-invoke Agent with gap appended to prompt
  - Retry schedule (agent phases only): retry 1 → original tier; retry 2 → upgrade (Haiku→Sonnet, Sonnet→Opus); retry 3 → halt rabbit hole (Sonnet-tier), or retry 4 → halt (Haiku-tier).
  - Inline phases: after 2 retries, escalate to agent/Haiku on retry 3, then halt on retry 4.

- **❌** → write checkpoint (`✗ failed`). Gate both modes:
  `⏸ retry · skip · replan · abort · instruct`
  - **retry**: re-invoke as-is
  - **skip**: surface full transitive dependent list, confirm, then mark ✗ skipped
  - **replan**: revised plan for remaining phases only
  - **abort**: delete state file, stop
  - **instruct**: user provides correction, append to prompt, re-invoke, reset retries to 0

---

## Auto Mode Loop

```
LOOP:
  1. Read state file — find ready phases
  2. None remain → Job Verification → Improvement Suggestions → TASK COMPLETE → delete state file
  3. Launch ready phases: inline (direct) or agent (Agent tool), parallel if multiple
  4. Run Steps A/B/C for each
  5. All ✅ → goto LOOP immediately (no pause)
  6. ⚠️ → Step C ⚠️ branch, goto LOOP
  7. ❌ → checkpoint all ✅ in batch, halt and gate user
```

Never stop between steps 5 and 1 in auto mode.

**Parallel batch mixed results:** checkpoint ✅ phases immediately; re-invoke ⚠️ phases; on any ❌ halt the batch and gate user with a summary of which passed/failed.

---

## Completion

**Archive state file** before deleting it:
1. Ensure `~/apps/ai-console/orchestrate-history/` exists (`mkdir -p`).
2. Copy `.task-orchestrate-state-{N}.md` there, renaming it to `<YYYYMMDD-HHMMSS>-<ticket-id>-<slug>.md` where `<ticket-id>` is the leading ticket/step identifier (e.g. `exec-1`, `mon-3`, `k6-5`) and `<slug>` is the remainder of the task summary lowercased, spaces → hyphens, truncated so the total filename is ≤ 80 chars.
3. Open the archive copy and add a `tags:` line to its frontmatter. Derive 4–8 tags from the task summary, project name, and phase summaries (ticket IDs, project names, key technologies, error keywords encountered).
4. Append one plain-text line to `~/apps/ai-console/orchestrate-history/MANIFEST.md`:
   `<YYYY-MM-DD> | <filename> | <task summary> | <tag1>, <tag2>, ...`
5. Delete the original `.task-orchestrate-state-{N}.md` from CWD.

This archive serves as context for future similar tasks — reference it when planning tasks with overlapping scope. Future agents find relevant archives via `grep "keyword" ~/apps/ai-console/orchestrate-history/MANIFEST.md` or `grep -rl "keyword" ~/apps/ai-console/orchestrate-history/`.

Also apply when **abort** is chosen in Step C ❌: archive before deleting.

Output:
```
TASK COMPLETE — <task>
✓ Phase 1 [inline · simple] — <summary>
✓ Phase 2 [inline · execution] — <summary>
✓ Phase 3 [agent/Sonnet] — <summary>
Outputs: <list>
```

**Job Verification (mandatory):**

```
── Job Verification ──────────────────────────────
Task:           <original task>
Phases:         X complete · Y failed/skipped
ACs covered:    ✓ Phase N · ✗ Phase N (reason) · N/A Phase N (simple/instructional)
Outputs exist:  <each declared output — present / missing>
Regressions:    none · or <description>
Confidence:     high | medium | low
──────────────────────────────────────────────────
```

If `low` confidence or any `✗` AC: gate both modes with `⚠ Verification found gaps: <list>` · `retry affected phases · replan · accept-as-is · abort`.

**Improvement Suggestions (mandatory):**

```
── Suggestions ───────────────────────────────────
Orchestrator:
  • <one suggestion for this skill's phasing, routing, or inline/agent split — or "none">

Skills invoked:
  • [/skill-name] <one concrete suggestion — or "none">
  • (none invoked)
──────────────────────────────────────────────────
```

**Backlog persistence:** After printing suggestions, check if any suggestion is non-trivial (not "none"). If so, append to `~/apps/ai-console/skill-improvement-backlog.md`. If the file is absent, create it first with this header:

```markdown
# Skill Improvement Backlog

Pending improvements captured from task-orchestrate completion suggestions.
To apply: `/task-orchestrate apply skill improvement backlog`

---
```

Then append one entry per run (multiple suggestions from the same run go under one header):

```markdown
## <YYYYMMDD> — <task-id>
- [orchestrator] <suggestion text>
- [/skill-name] <suggestion text>
  Source: <archive filename>
```

This file is the durable backlog. A future `/task-orchestrate` run can be given "apply skill improvement backlog" as its task to batch-apply pending items. Do NOT write "none" entries — only substantive, actionable suggestions.

---

## Rabbit Hole Prevention

After 4 retries on the same phase (3 for Sonnet-tier), halt:

```
⚠️ Phase N appears stuck (<brief diagnosis>).
Revised plan for remaining work:
[re-planned phases from N onward]
⏸ "go" to adopt · "abort" · describe changes
```

Distinguish: **compression-loss** (context compressed 3+ times — suggest splitting the phase) vs **execution-stuck** (same error repeating — suggest replan or manual intervention).

---

## MCP Gates

Annotate MCP phases `[MCP: service-name]`. Pre-authorize at plan time via `"go auto, approve MCP: X, Y"` — record in `mcp_preauthorized`. Mid-flow: pause before each MCP phase unless pre-authorized.
