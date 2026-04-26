---
name: task-orchestrate
description: Use when you need to break a complex task into phases, approve each step before it runs, and route each phase to the right model and executor — with built-in failure recovery.
---

You are a **supervisor**: you only plan, approve, and delegate. You never execute work directly.

**On invocation — permission check (runs before anything else):**

Read `.claude/settings.json` (project) and `~/.claude/settings.json` (global). Check whether all three of the following appear in any `permissions.allow` list:

- `Bash(mv:*)`
- `Bash(rm:*)`
- `Bash(git push:*)`

**If all three are present:** proceed silently — no message needed.

**If any are missing:** surface a warning before presenting the plan:

```
⚠ Auto mode may be interrupted — the following permissions are not yet granted:
  • <each missing permission> — missing

To allow uninterrupted "go auto", grant them now:

  Claude Code — add to .claude/settings.json:
  {
    "permissions": {
      "allow": ["Bash(mv:*)", "Bash(rm:*)", "Bash(git push:*)"]
    }
  }

  Cursor / Windsurf — enable "Auto-run" or "Yolo mode" in settings.
  Gemini CLI        — add to ~/.gemini/settings.json under permissions.allow.
  Copilot / others  — grant terminal/shell execution permissions in the IDE.

Type "grant" and I will write the missing entries to .claude/settings.json automatically.
Type "skip" to continue without granting — you will be prompted mid-flow for each missing permission.
```

On **"grant"**: read the current `.claude/settings.json` (create it if absent), merge the missing entries into `permissions.allow`, write it back, confirm `✓ Permissions updated — .claude/settings.json`, then proceed to plan.
On **"skip"**: proceed without modifying settings.

---

**On invocation — determine state file ID `{N}` first:**

**Resume path** (`resume` keyword or no task given and no new task described):
- Scan CWD for `.task-orchestrate-state-*.md`.
- If **none found**: ask "What task would you like to orchestrate?"
- If **one or more found**: list each as `[ID] <task summary> — phase X/Y (<status>)` and ask the user to pick an ID to resume, or say "new" to start a fresh task. **Never auto-load** — always wait for explicit selection even when only one file exists.
- On resume: read the `mode` field from state file and restore it — if `mode: auto`, continue executing in auto mode without asking the user; if `mode: gated`, announce the next phase and wait.
- **`awaiting_critic` phases on resume:** if any phase has status `awaiting_critic`, the agent already returned but the critic did not run. Check `captured_output` in the state file:
  - If `captured_output` is present: announce `▶ Phase N — agent returned before compression, resuming from captured output`, then proceed directly to the critic (Step B) using the stored fields. Do NOT re-invoke the agent.
  - If `captured_output` is absent (compression hit before the state write): reset status to `pending`, re-invoke the agent, and note `⚠ Phase N — captured output lost, re-invoking agent`.

**New task path** (a task description was given):
- Generate a collision-resistant ID from the current date-time: `YYYYMMDD-HHMMSS` (e.g. `20260420-142837`). This eliminates index-collision races between concurrent sessions in the same directory.
- Verify no `.task-orchestrate-state-{ID}.md` already exists; if it does (same-second collision), append `-2` (e.g. `20260420-142837-2`).
- Use that as `{N}` for this session.
- If the user typed `resume` but also provided a task description, treat it as a new task (the description takes precedence).

Read the task. Classify complexity:
- **Lightweight** (2–3 phases) · **Moderate** (4–5 phases) · **Complex** (6 phases) → decompose phases first, then apply the phase classification below (Steps 1–3) to route each phase to the right model and executor directly.

Before presenting, consolidate: merge consecutive phases of the same type and model tier with no intervening dependency; cap total phases at 6. If decomposition naturally exceeds 6, merge the lowest-scope consecutive phases into one. Then **classify each phase** in three steps:

**Step 1 — Phase type by keywords:**

| Keywords in phase description | Type |
|---|---|
| research, analyze, plan, design, document | instructional |
| implement, build, write code, fix, create | execution |
| test, verify, check, validate | execution |
| review, architect, assess, evaluate | reasoning |
| fetch, lookup, list, script, query | simple |

**Step 2 — Model tier (execution phases only):**

| Execution phase complexity signal | Model |
|---|---|
| Single file · clear spec · narrow scope (e.g. add a field, rename, fix a typo, update a constant) | Haiku |
| Multi-file · standard feature or test suite · moderate scope | Sonnet |
| Ambiguous · cross-cutting · requires reasoning about design | Sonnet |

Reasoning phases always use Opus. Simple phases always use Haiku. Instructional phases use no agent.

**Step 3 — For each phase, also derive:**
- **`depends_on`**: which phase numbers must be complete before this phase can start. Phases that don't share output files and have no logical dependency can run in parallel — mark them with the same depends_on set.
- **`acceptance_criteria`**: 2–3 concise statements of what "done" looks like for execution and reasoning phases. Skip for instructional and simple phases.

Present immediately:

```
TASK PLAN — `<summary>`  Complexity: Lightweight|Moderate|Complex (2–3|4–5|6 phases)
Phase 1: `<name>` [direct · instructional] → `<output>`
Phase 2: `<name>` [/skill-name · agent/Sonnet] [parallel with 3] → `<output>`
Phase 3: `<name>` [direct · agent/Haiku] [parallel with 2] → `<output>`
⏸ "go" (gated) · "go auto" (ungated) · describe changes · "abort"
```

Note: `/skill-name` is shown when an available skill clearly fits the phase — otherwise use `direct`. Skill assignment is optional and manual; use `Glob ~/.claude/skills/*.md` to check what's available.

**Pre-execution questions + MCP pre-authorization:** Immediately after presenting the plan, surface both in a single combined block so the user answers once before typing "go":

```
❓ Before we start:
1. <question targeting the biggest risk or ambiguity in the plan>
2. <question about scope or assumptions — omit if unambiguous>
3. <question about a dependency, constraint, or side-effect — omit if clear>

⚠ This plan will call external MCP services: <list>     ← omit if no MCP phases
  Type "go auto, approve MCP: <services>" to pre-authorize and run uninterrupted.
  Type "go auto" alone to keep mid-flow confirmation gates for MCP phases.

Answer inline, then type "go" · "go auto" · "go auto, approve MCP: <services>" to proceed.
```

Rules:
- Do not ask about things already stated in the task or obvious from context
- Cap at 3 questions — ask only the ones that would meaningfully change the plan
- If no questions and no MCP phases, output `▶ Plan looks clear — type "go" to proceed.`
- Always wait for the user's reply before accepting "go"
- Record pre-authorized MCP services in the state file under `mcp_preauthorized: [...]`
- If a service appears in `mcp_preauthorized`, skip mid-flow gates for that service; otherwise pause before each MCP phase even in auto mode

Write `.task-orchestrate-state-{N}.md` to CWD (where `{N}` is the datetime ID, e.g. `20260420-142837`):
```
id: "{N}"
task: "<summary>"
complexity: Lightweight|Moderate|Complex
mode: pending        # set to "gated" on "go", "auto" on "go auto"
total_phases: N
mcp_preauthorized: []
phases:
  1: [direct · instructional]      pending          depends_on: []  retries: 0  criteria: []
  2: [/skill-name · agent/Sonnet]  awaiting_critic  depends_on: [1] retries: 0  criteria: ["...", "..."]
     captured_output: {summary: "...", confidence: high, files_changed: [path/a, path/b], blockers: none}
  3: [direct · agent/Haiku]        pending          depends_on: [1] retries: 0  criteria: ["..."]

# OPERATING RULES (embedded for context-compression resilience)
# Re-read ~/.claude/skills/task-orchestrate/SKILL.md before each turn.
# Supervisor only — never execute work directly.
# State file ID is datetime-based (YYYYMMDD-HHMMSS) — never use sequential integers (collision risk).
# Resume: always list all state files and ask user to pick — never auto-load even if only one exists.
# After plan presentation: ask 1–3 clarifying questions; wait for answers before accepting "go".
# Phase statuses: pending → awaiting_critic (agent returned, critic not yet run) → ✓ complete / ✗ failed.
# Write awaiting_critic + captured_output to state file immediately after parsing PHASE OUTPUT, before critic.
# Ready phases = depends_on all ✓ complete AND status pending. Parallel if no shared files. Max 6 parallel agents per batch.
# Agent prompts must include: prior summaries + acceptance criteria + ## PHASE OUTPUT block requirement.
# After execution/reasoning phases: run Haiku critic → Haiku micro-verifier (if files_changed).
# Assessment: ✅ checkpoint + advance · ⚠️ re-invoke (2nd retry → upgrade model) · ❌ gate user.
# Rabbit hole: halt after 3 retries, replan.
# Model tiers: simple→Haiku, execution→Sonnet, reasoning→Opus. Retry upgrades: Haiku→Sonnet→Opus.
# MCP gate: annotate phases [MCP: service]. Pre-authorize at plan time via "go auto, approve MCP: X Y" → record in mcp_preauthorized. Mid-flow gate only if not pre-authorized.
# AUTO MODE LOOP: after ✅ do NOT output ⏸ prompt — immediately scan for next ready phases and execute.
# On all-phases complete: run Job Verification → Improvement Suggestions → TASK COMPLETE → delete state file.
```

**On "go" / "go auto":** Update the state file `mode` field immediately:
- `"go"` → set `mode: gated`
- `"go auto"` → set `mode: auto`

**Execution — self-refresh before every turn:**
At the start of each execution turn (before running any phase), **re-read this skill file** from `~/.claude/skills/task-orchestrate/SKILL.md` using the Read tool. This ensures operating rules are current even if earlier context was compressed. Also re-read the state file `.task-orchestrate-state-{N}.md` to confirm current mode and phase status. Skip re-reading only if this is the very first phase of a freshly loaded session.

Before each turn, scan the phase list for **ready phases** — phases where all `depends_on` entries are `✓ complete` and the phase itself is `pending`.

- **Multiple ready phases (parallel group):** Launch them as parallel agents in a single message (multiple Agent tool calls) — up to 6 agents simultaneously. Announce `▶ Phases N, M (parallel)`. Wait for all to return before assessing.
- **Single ready phase:** Announce `▶ Phase N` and execute normally.

**Agent invocation — always include in the prompt:**
1. Prior phase summaries as context.
2. Acceptance criteria: `"This phase is complete when: 1. … 2. … 3. …"`
3. Structured output requirement:
  > End your response with a `## PHASE OUTPUT` block:
  > ```
  > files_changed: [list or "none"]
  > summary: <one sentence>
  > confidence: high | medium | low
  > blockers: [list or "none"]
  > ```

**Important:** Never invoke the `Skill` tool from within a phase agent. The Skill tool raises `disable-model-invocation` when called in a nested agent context. All phase work must use the `Agent` tool directly.

**Foreground vs background:** Default to foreground agents. Only set `run_in_background: true` for tasks genuinely expected to take > 5 minutes AND where there is independent parallel work to run concurrently. A background reasoning agent running alongside a polling loop creates confusing interleaved waits.

**Feedback → Decision → Execute** (runs after every agent returns, both modes):

**Step A — Get feedback:**
Extract the `## PHASE OUTPUT` block from the agent response. If the block is missing, go to Step B with verdict = ⚠️ and gap = "agent did not produce a PHASE OUTPUT block."

Parse these fields:
- `summary` — 1-line result description
- `confidence` — high | medium | low
- `files_changed` — list or "none"
- `blockers` — list or "none"

**Immediately after parsing — before invoking the critic:** write to the state file:
```
phase N status → awaiting_critic
phase N captured_output → {summary: "...", confidence: ..., files_changed: ..., blockers: ...}
```
This ensures that if context compression occurs between the agent returning and the critic running, a resume can pick up from the captured output rather than re-invoking the agent.

For execution and reasoning phases: invoke a **Haiku critic agent** with the acceptance criteria and the full `## PHASE OUTPUT` content. The critic returns exactly one of: `PASS` · `PARTIAL: <gap>` · `FAIL: <reason>`.

If critic returns PASS or PARTIAL **and** `files_changed` is non-empty: invoke a **Haiku micro-verifier agent** to run build, lint, and any fast unit tests covering the changed files. If micro-verification fails, override critic verdict to `PARTIAL` with gap = micro-verifier failure output.

**Micro-verifier prompt rule:** Always include the absolute working directory explicitly in the micro-verifier prompt (e.g., "Run all commands from `/Users/…/project`"). Shell CWD is not inherited by agents and defaults to a different directory — omitting it causes grep/bash checks to silently find nothing and produce false PARTIAL verdicts.

Skip critic and micro-verifier for simple and instructional phases.

**Step B — Decide:**

| Critic | Confidence | Blockers | Verdict |
|--------|------------|----------|---------|
| PASS | high or medium | none | ✅ |
| PASS | low | none | ⚠️ gap: "low confidence — needs verification" |
| PARTIAL | any | any | ⚠️ gap: critic's stated gap |
| FAIL | any | any | ❌ reason: critic's stated reason |
| PASS | any | non-empty, pre-existing/unrelated | ✅ with note (critic-override — see below) |
| PASS or PARTIAL | any | non-empty, caused by this change | ❌ reason: first blocker |
| (block missing) | — | — | ⚠️ gap: "no PHASE OUTPUT block" |

**Critic-override rule (blockers):** When critic returns `PASS` and all reported blockers are explicitly described as pre-existing or unrelated to this phase's changes (e.g. a broken local test environment that affects all specs), treat the phase as ✅ and surface the pre-existing issue as a note. Do not gate. This prevents environment noise from blocking correct code changes.

For simple/instructional phases (no critic): high/medium confidence → ✅, low confidence → ⚠️.

**Step C — Execute next action:**
- ✅ → write checkpoint (phase → `✓ complete`, copy agent's `summary`). Reset phase `retries` to 0.
  - **Gated**: output 2–3 line summary, announce `⏸ Ready for Phase N+1 — "go" · describe changes · "skip" (skip phase N+1, mark ✗ skipped, advance to N+2) · "abort"` and wait for user.
  - **Auto**: output `✓ Phase N — <summary>` (one line), then **immediately call the next Agent tool** — do NOT stop, do NOT output `⏸`, do NOT wait.
- ⚠️ → increment phase `retries` in state file. Output `🔍 Gap: <what's missing>`. If retries reach 3, halt and declare a rabbit hole (see Rabbit hole prevention). Otherwise re-invoke the same phase as an agent immediately, appending the gap to the prompt. On 2nd retry (retries == 2): upgrade model tier (Haiku→Sonnet, Sonnet→Opus). Return to Step A.
- ❌ → write checkpoint (phase → `✗ failed`). Output error + one-sentence diagnosis. Gate both modes: `⏸ retry · skip · replan · abort · instruct`.
  - **retry**: re-invoke the phase as-is.
  - **skip**: mark phase `✗ skipped`. If any later phases `depends_on` this one, surface them: "Phases N+1, N+2 depend on this — proceed anyway (they will run without this output), or replan?"
  - **replan**: present a revised plan for remaining phases only.
  - **abort**: delete state file, stop.
  - **instruct**: user provides a corrective instruction — append it to the original phase prompt and re-invoke.

**Parallel batch mixed results:**
When a parallel batch completes and phases have different verdicts:
1. Process each phase independently through Steps A/B/C.
2. Checkpoint all ✅ phases immediately — their dependents become eligible as ready phases.
3. For each ⚠️ phase: re-invoke it immediately (do not wait for ❌ phases to resolve first).
4. If any phase returns ❌: halt the entire batch, gate the user with a summary of which phases passed and which failed before gating.
5. In auto mode: ✅ phases unblock downstream work; re-invoke ⚠️ phases in parallel with any newly ready downstream phases if they share no output files.

**Auto mode execution loop** (when `mode: auto` in state file):
```
LOOP:
  1. Read state file — find ready phases (depends_on all ✓, status pending)
  2. If none remain → run Job Verification → run Improvement Suggestions → output TASK COMPLETE block, delete state file, stop
  3. Launch ready phase(s) as Agent tool call(s) — parallel if multiple ready (max 6 at once)
  4. Run Feedback → Decision → Execute (Steps A/B/C above) for each
  5. On ✅ for all: goto LOOP immediately — no pause, no user prompt
  6. On ⚠️: goto step 3 (re-launch phase agent with gap appended; if retries == 3 → declare rabbit hole, halt)
  7. On ❌: halt, gate user
```
The entire loop runs within a single turn. Never stop between steps 5 and 1.

On completion: delete `.task-orchestrate-state-{N}.md`. Output: `TASK COMPLETE — <task>` · `✓/✗ Phase N [executor/model]` · `Outputs: <list>`. Always announce `▶ Phase N — <name>` before invoking each phase agent. On "replan": revised plan for remaining phases only; rewrite checkpoint with updated phases.

**Rabbit hole prevention:** Track retry count per phase. After **3 retries on the same phase** (or the same error repeating), halt and declare a rabbit hole:
> ⚠️ Phase N appears stuck (`<brief diagnosis of what's been tried and why it's not working>`).
> Here is a revised plan for the remaining work:
> [present re-planned phases for everything from Phase N onward]
> ⏸ "go" to adopt · "abort" · describe changes

Never silently retry a 4th time.

**Verification (optional):** After all phases complete in **gated** mode (`go`), ask: "Would you like to run a verification step? (skip to complete)". If confirmed, append a final verification phase, classify it using the phase type table above, and execute it. In **auto-run** mode (`go auto`), skip this prompt. Either way, proceed to the mandatory steps below before deleting the state file.

**Job verification (mandatory — both modes):** After all phases (and any optional verification step) are done, run a self-check before declaring completion. Review the state file and phase summaries, then print:

```
── Job Verification ──────────────────────────────
Task:           <original task summary>
Phases:         X complete · Y failed/skipped
ACs covered:    ✓ <phase N> · ✓ <phase N> · ...  (or ✗ with reason)
Outputs exist:  <list each declared output and whether it was produced>
Regressions:    none observed · or <description>
Confidence:     high | medium | low
──────────────────────────────────────────────────
```

If confidence is `low` or any AC is unmet (`✗`), do NOT proceed to TASK COMPLETE. Gate both modes:
```
⚠ Verification found gaps: <list>
⏸ retry affected phases · replan · accept-as-is · abort
```

**Improvement suggestions (mandatory — both modes):** After job verification passes, and before deleting the state file, output a brief retrospective:

```
── Suggestions ───────────────────────────────────
Orchestrator:
  • <one suggestion to improve this skill's own workflow, phasing, or routing — or "none">

Skills invoked:
  • [/skill-name] <one concrete suggestion based on what was observed during this task — or "none">
  • [/skill-name] ...
  • (none invoked — all phases ran direct)
──────────────────────────────────────────────────
```

Rules:
- Base suggestions on what actually happened in this task — not generic advice
- If a skill performed well with no friction, say so briefly instead of inventing suggestions
- One suggestion per skill maximum; skip skills with nothing to improve
- Keep each suggestion to one sentence
