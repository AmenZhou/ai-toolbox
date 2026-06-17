---
name: task-orchestrate
description: Unified project orchestrator with built-in watchdog. Maintains a project-scoped control plane (.orchestrate/) with shared context across all tasks, a task registry, and an inbox drop-zone. Phases, critic, and quality gates are unchanged. Built-in "tend" mode replaces the separate task-supervisor skill. Use for any task: simple fire-and-forget or complex multi-phase work. The watchdog runs as an OS-level heartbeat — no separate /loop needed.
inline: false
---

You are the **orchestrator**: you plan, approve, and execute — running phases inline with your own tools when that's efficient, spawning agents only when truly needed. You also maintain a project-scoped control plane and watch your own task registry for stalls.

**Spawn an agent only when:**
1. A phase is too large to fit in the main context (~10+ tool calls or 3+ files to create/rewrite)
2. Genuine parallelism is needed
3. A skill's embedded instructions make isolation valuable

For everything else, run inline.

**Note on task-supervisor:** That skill is deprecated. Supervision is now built in here via `tend` mode.

---

## Invocation Modes

Detect which mode applies from the input:

| Input | Mode |
|-------|------|
| `tend` | Watchdog — scan registry, advance stalled tasks |
| `resume` alone | Resume — list active tasks and wait for user pick |
| Any other non-empty string | New task — plan and execute |
| Empty / no input | If project.md exists: show registry status. Else: ask for task. |

---

## Project Structure

All state lives under `.orchestrate/` in the **current working directory**. Create this layout on first use in any project:

```
.orchestrate/
  project.md          # control plane: shared context + task registry
  tasks/              # per-task phase files (one per active task)
  inbox/              # drop-zone: a .md file here = a task to register
  logs/
    heartbeat.log     # one line per tend cycle
```

### project.md

```markdown
# Orchestrate — {project name or cwd basename}
last_updated: <ISO>

## Shared Context
<!-- Durable project knowledge carried across tasks.
     Append discoveries here at task completion.
     Every new task reads this before planning. -->

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
```

Status values: `pending` · `running` · `awaiting_go` · `awaiting_critic` · `complete` · `failed` · `needs_human`

### Per-task file — `.orchestrate/tasks/{ID}.md`

Same schema as the former `.task-orchestrate-state-{ID}.md`. The `id`, `task`, `complexity`, `mode`, `total_phases`, `phases` block and OPERATING RULES are identical — only the file location changes.

---

## Permission Check

Read `.claude/settings.json` (project) and `~/.claude/settings.json` (global). Check `permissions.allow` for: `Bash(mv:*)`, `Bash(rm:*)`, `Bash(git push:*)`.

**All present:** proceed silently.

**Any missing:** surface once before presenting the plan:
```
⚠ Auto mode may be interrupted — missing permissions: <list>
Type "grant" · "grant global" · "skip"
```
On "grant"/"grant global": merge missing entries into settings, confirm `✓ Permissions updated`.

---

## Tend Mode (built-in watchdog)

Invoked by the word `tend` or by the OS-level heartbeat (see Heartbeat Setup). Runs a lightweight cycle over the project registry. **Token cost on idle cycle: this file only.**

### T-0 — Lock

```bash
LOCK=.orchestrate/.tend.lock
if [ -f "$LOCK" ]; then
  AGE=$(( $(date +%s) - $(date -r "$LOCK" +%s) ))
  [ $AGE -lt 360 ] && echo "Tend already running (${AGE}s). Exiting." && exit 0
fi
date -u +%Y-%m-%dT%H:%M:%SZ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT
```

### T-1 — Pre-flight (bash, no LLM context on idle)

```bash
PROJ=.orchestrate/project.md
NEED_ACTION=0

# Stalled tasks in registry?
grep -qE "awaiting_critic|awaiting_go" "$PROJ" 2>/dev/null && NEED_ACTION=1

# Inbox has items?
ls .orchestrate/inbox/*.md 2>/dev/null | grep -q . && NEED_ACTION=1
```

If `NEED_ACTION=0`: append `[<ISO>] tend — idle` to `.orchestrate/logs/heartbeat.log` and exit.

### T-2 — Drain inbox

**Inbox file format** (required for all enqueued tasks — human or automated):

```markdown
# <short task title>

## Goal
<1–3 sentences: what must be true when this task is done. Be specific — name files, endpoints, or behaviors.>

## Context
<Relevant background: which files are involved, what's already been tried, constraints, related tasks by ID.>

## Acceptance Criteria
- <measurable done-statement 1>
- <measurable done-statement 2>
```

When reading an inbox file:
- If the file is plain text (no `## Goal` section): treat the entire content as the goal, but flag at registration: `⚠ inbox file <name> has no structured context — plan phase may need clarification`.
- If the file has the structured format: extract Goal as task summary, Context as shared background for the plan phase, ACs as phase acceptance criteria seeds.

For each `.md` file in `.orchestrate/inbox/`:
1. Read the file — extract title/goal.
2. Register it in the project registry (status: `pending`, no phase file yet).
3. Move file to `.orchestrate/inbox/processed/`.
4. Append to `.orchestrate/logs/heartbeat.log`: `[<ISO>] inbox — registered "<task title>" from <filename>`
5. Do **not** start execution — queued tasks wait for `go`/`go auto`.

When a background inbox task is later executed (via `go auto` in tend mode), write a per-task log file at `.orchestrate/logs/{ID}-tend.log`:
```
=== Tend-driven execution — <ISO> ===
source: inbox/<original-filename>
task: <prompt>
<append each PHASE OUTPUT block as phases complete>
=== done ===
```

### T-3 — Load tools

`ToolSearch: "select:PushNotification"` — load only now that action is confirmed needed.

### T-4 — Scan registry

For each task in the registry:

**`awaiting_critic` (mode: auto):** Read its task file (`.orchestrate/tasks/{ID}.md`). Re-read this SKILL.md's Critic section. Run critic assessment inline. Write verdict + checkpoint. If ✅ and mode auto: continue execution loop. Append action to heartbeat.log.

**`awaiting_go` (mode: gated):** Do NOT advance. Send `PushNotification`: `⏸ [{ID}] "{summary}" — phase ready, needs your "go"`. Log it.

**`pending` tasks registered from inbox:** Send `PushNotification`: `📋 [{N} new task(s) queued — type "go" or "go auto" to start]`. Log.

**All other statuses:** skip.

### T-5 — Update shared context (after any completions this cycle)

If any tasks moved to `complete` this cycle: see **Shared Context Update** section below.

### T-6 — Release lock

Lock is released by the `trap` from T-0.

---

## State File & Resume

**New task:** Generate ID `YYYYMMDD-HHMMSS`. Create `.orchestrate/tasks/{ID}.md`. Ensure `.orchestrate/project.md` exists (create with template if not). Register row in project.md registry.

**Resume:** Scan `.orchestrate/tasks/` for active task files.
- None found → ask "What task would you like to orchestrate?"
- One or more found → list `[ID] <task> — phase X/Y (<status>)`. Files with `mode: pending` older than 7 days are abandoned — list separately, offer to delete.
- **Always wait for user to pick an ID** — never auto-load.
- On resume: restore `mode`. If `pending`, re-present plan. If `auto`, continue immediately.
- `awaiting_critic` on resume: check `captured_output`. If present: skip pre-critic write, go directly to inline assessment. If absent: reset to `pending`, increment retries, re-invoke.

**`resume` must be the full input.** Any other input is a new task.

---

## Phase Classification

Classify task complexity: **Lightweight** (2–3) · **Moderate** (4–5) · **Complex** (6). Merge consecutive same-type phases; cap at 6.

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
| execution — narrow (≤2 files, clear spec, ≤5 tool calls) | **inline** |
| skill phase where skill declares `inline: true` | **inline · /skill-name** |
| research / investigation / challenging analysis | **agent/premium** |
| execution — moderate or broad (3+ files, iterative) | **agent/Sonnet** |
| reasoning phase | **agent/Sonnet** |
| any phase that must run in parallel | **agent/*** |
| skill phase without `inline: true` | **agent/** at tier |

### Step 3 — Derive per phase

- `depends_on`: phase numbers that must complete first
- `acceptance_criteria`: 2–3 done-statements for execution/reasoning phases

---

## Plan Presentation

Read `## Shared Context` from `project.md` before planning — it contains durable decisions and constraints from prior tasks. Incorporate relevant context into the plan (phase design, executor choices, acceptance criteria).

```
TASK PLAN — `<summary>`  Complexity: Lightweight|Moderate|Complex (N phases)
Phase 1: `<name>` [inline · simple] → `<output>`
Phase 2: `<name>` [inline · execution] → `<output>`
Phase 3: `<name>` [/skill-name · agent/Sonnet] [parallel with 4] → `<output>`
Phase 5: `<name>` [agent/premium] → `<output>`   ← research/investigation
```

Surface pre-execution questions:
```
❓ Before we start:
1. <biggest risk or ambiguity>
2. <scope or assumption>
3. <dependency or side-effect>

⚠ MCP services involved: <list>   ← omit if none

Answer inline, then: "go" (gated) · "go auto" (ungated) · describe changes · "abort"
```

If no questions and no MCP: `▶ Plan looks clear — type "go" or "go auto" to proceed.`

Write task file to `.orchestrate/tasks/{ID}.md`. Register row in `project.md` with `status: awaiting_go`.

---

## On "go" / "go auto"

Update task file `mode` immediately:
- `"go"` → `mode: gated`
- `"go auto"` → `mode: auto`
- `"go auto, approve MCP: <list>"` → `mode: auto`, `mcp_preauthorized: [<list>]`
- Free-form → treat as plan revision, re-present.

Update project.md registry row: `status: running`.

---

## Execution Loop

**Self-refresh at start of each turn:** re-read this skill file and the task file. Skip only if this is the first turn after Skill tool was just invoked.

**Ready phases** = all `depends_on` entries are `✓ complete` AND status is `pending`.

### Inline phase execution

Run the phase directly with your own tools. When done, produce:

```
## PHASE OUTPUT
files_changed: [list or "none"]
summary: <one sentence>
confidence: high | medium | low
blockers: [list or "none"]
```

Evaluate against acceptance criteria inline. Assign: **PASS** · **PARTIAL: \<gap\>** · **FAIL: \<reason\>**.

If `files_changed` non-empty: run Bash lint/build/test. Downgrade to PARTIAL if fails.

**Phase log write (mandatory):** Append the full PHASE OUTPUT block to `.orchestrate/logs/{ID}-phase{N}.log`:
```bash
mkdir -p .orchestrate/logs
echo "=== Phase N — <name> $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> .orchestrate/logs/{ID}-phase{N}.log
echo "<full PHASE OUTPUT block>" >> .orchestrate/logs/{ID}-phase{N}.log
```

**State write is mandatory after every inline phase** — follow Steps A/B/C immediately. Never defer or batch.

**Inline skill invocation:** For `[inline · /skill-name]` phases, read the skill's SKILL.md, follow its instructions directly. Announce `▶ Phase N — <name> (inline)`.

### Agent phase execution

Announce `▶ Phase N — <name>`.

**Agent prompt must include:**
1. Prior phase summaries
2. Absolute working directory
3. `## Shared Context` from project.md (paste verbatim — gives agent project-level knowledge)
4. Acceptance criteria: "This phase is complete when: 1. … 2. … 3. …"
5. Required output: `## PHASE OUTPUT` block with files_changed / summary / confidence / blockers
6. If skill embedded: paste SKILL.md body directly — do NOT invoke Skill tool from within agent

**Parallel phases:** launch as multiple Agent calls in one message (max 6). Wait for all before assessing.

**Foreground vs background:** default foreground. Use `run_in_background: true` only when > 5 min expected AND there is independent work to run concurrently.

After agent returns: extract `## PHASE OUTPUT`. If missing → treat as ⚠️ with gap "no PHASE OUTPUT block".

**Phase log write (mandatory):** Append the full PHASE OUTPUT block (or the raw agent return text if block is missing) to `.orchestrate/logs/{ID}-phase{N}.log` — same format as inline phases above.

### Critic & micro-verifier (always inline)

For execution and reasoning phases:
- **PASS** — all criteria met
- **PARTIAL: \<gap\>** — most criteria met, one gap
- **FAIL: \<reason\>** — key criterion not met or blocker caused by this change

If `files_changed` non-empty: run Bash verify (build, lint, fast tests). Override to PARTIAL if fails.

Classify blockers: `pre-existing` or `caused-by-change`. Pre-existing → note only, do not downgrade.

Skip assessment for simple and instructional phases.

---

## Feedback → Decision → Execute (Steps A/B/C)

**Step A — Capture:**
```
phase N status → awaiting_critic
phase N captured_output → {summary, confidence, files_changed, blockers}
phase N raw_output → <full PHASE OUTPUT block text>
```
Append the raw output block to the task state file under the phase section (so `.orchestrate/tasks/{ID}.md` contains a full record of what Claude produced). Update project.md registry: `status: awaiting_critic`.

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

Simple/instructional: high/medium confidence → ✅, low → ⚠️.

**Step C — Act:**

- **✅** → write checkpoint (`✓ complete`, copy summary). Reset retries to 0. Update project.md: `current_phase += 1`.
  - Gated: `⏸ Ready for Phase N+1 — "go" · changes · "skip" · "abort"`
  - Auto: `✓ Phase N — <summary>`, immediately execute next ready phase(s)

- **⚠️** → increment retries. `🔍 Gap: <what's missing>`. Re-invoke with gap appended.
  - Retry schedule (agent phases): retry 1 → original tier; retry 2 → upgrade (Haiku→Sonnet, Sonnet→premium); retry 3 → halt (Sonnet-tier) or retry 4 → halt (Haiku-tier). Premium: retry 1 → premium; retry 2 → halt.
  - Inline phases: after 2 retries, escalate to agent/Haiku on retry 3, halt on retry 4.

- **❌** → write `✗ failed`. Update project.md: `status: needs_human`.
  - Gate both modes: `⏸ retry · skip · replan · abort · instruct`

---

## Auto Mode Loop

```
LOOP:
  1. Read task file — find ready phases
  2. None remain → Completion → exit loop
  3. Launch ready phases: inline (direct) or agent (Agent tool), parallel if multiple
  4. Run Steps A/B/C for each
  5. All ✅ → goto LOOP immediately
  6. ⚠️ → Step C ⚠️ branch, goto LOOP
  7. ❌ → checkpoint all ✅ in batch, halt and gate user
```

Never stop between steps 5 and 1 in auto mode.

**Parallel batch mixed results:** checkpoint ✅ immediately; re-invoke ⚠️; on any ❌ halt and gate.

---

## Completion

When all phases are `✓ complete`:

**1. Archive task file:**
- Ensure `~/apps/ai-console/orchestrate-history/` exists.
- Copy `.orchestrate/tasks/{ID}.md` → `orchestrate-history/<YYYYMMDD-HHMMSS>-<ticket-id>-<slug>.md`
- Add `tags:` line to archive copy. Append one line to `orchestrate-history/MANIFEST.md`.
- Delete original task file from `.orchestrate/tasks/`.

**2. Update project.md registry:** set `status: complete`, `last_activity: now`.

**3. Update Shared Context** — see section below.

**4. Auto-Verification Run:**

Before producing the Job Verification summary, run automated checks and write results to `.orchestrate/logs/{ID}-verify.log`:

```bash
# Detect and run test/build commands (try each; skip if not found)
VERIFY_LOG=".orchestrate/logs/${ID}-verify.log"
echo "=== Verification run $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$VERIFY_LOG"

# Check declared output files exist
for f in <files_changed from all phases>; do
  [ -f "$f" ] && echo "✓ $f" >> "$VERIFY_LOG" || echo "✗ MISSING: $f" >> "$VERIFY_LOG"
done

# Auto-detect and run test/build commands (try each in order; stop at first match)
if [ -f "package.json" ]; then
  (npm test 2>&1 | tail -20) >> "$VERIFY_LOG" || true
  (npm run build 2>&1 | tail -20) >> "$VERIFY_LOG" || true
elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
  (python -m pytest --tb=short -q 2>&1 | tail -20) >> "$VERIFY_LOG" || true
elif [ -f "Makefile" ]; then
  (make test 2>&1 | tail -20) >> "$VERIFY_LOG" || true
elif [ -f "go.mod" ]; then
  (go test ./... 2>&1 | tail -20) >> "$VERIFY_LOG" || true
else
  echo "no test runner detected — skipping" >> "$VERIFY_LOG"
fi

echo "=== done ===" >> "$VERIFY_LOG"
```

Classify verify result: **✓ passed** · **⚠ warnings** · **✗ failed**. Include result in Job Verification block. If `✗ failed` and failure is caused-by-change: gate before archiving.

**5. Job Verification:**
```
── Job Verification ──────────────────────────────
Task:           <original task>
Phases:         X complete · Y failed/skipped
ACs covered:    ✓ Phase N · ✗ Phase N · N/A Phase N
Outputs exist:  <each declared output — present / missing>
Verify run:     ✓ passed | ⚠ warnings | ✗ failed | skipped
Regressions:    none · or <description>
Confidence:     high | medium | low
──────────────────────────────────────────────────
```

If low confidence or any ✗ AC: gate with `⚠ Verification found gaps`.

**6. Improvement Suggestions:**
```
── Suggestions ───────────────────────────────────
Orchestrator:
  • <one suggestion — or "none">
Skills invoked:
  • [/skill-name] <suggestion — or "none">
──────────────────────────────────────────────────
```

If non-trivial: append to `~/apps/ai-console/skill-improvement-backlog.md`.

**Output:**
```
TASK COMPLETE — <task>
✓ Phase 1 [inline · simple] — <summary>
✓ Phase 2 [agent/Sonnet] — <summary>
Outputs: <list>
```

---

## Shared Context Update

After every task completion, extract durable project knowledge and append it to `project.md ## Shared Context`. This is what makes future tasks smarter — don't skip it.

What to append (only if genuinely new and not already there):
- **Architectural decisions** made during this task ("using Postgres for X, not ClickHouse")
- **API/service behavior** discovered ("endpoint Y returns 429 after 100 req/min")
- **Recurring constraints** ("all migrations must be backward-compatible with the running service")
- **Conventions established** ("new files in this module use camelCase, not snake_case")
- **Known failure modes** ("bfs find does not support -newermt; use -mmin instead")

What NOT to append:
- Task-specific details that don't apply to other tasks
- Information already in the codebase or CLAUDE.md
- Anything ephemeral

Format — append as bullets under a dated heading:
```markdown
### {YYYY-MM-DD} — {task summary}
- <finding 1>
- <finding 2>
```

---

## Rabbit Hole Prevention

After 4 retries (3 for Sonnet-tier, 2 for premium-tier):

```
⚠️ Phase N appears stuck (<diagnosis>).
Revised plan:
[re-planned phases from N onward]
⏸ "go" to adopt · "abort" · describe changes
```

Distinguish **compression-loss** (context compressed 3+ times → suggest splitting phase) vs **execution-stuck** (same error repeating → suggest replan or manual intervention).

---

## MCP Gates

Annotate MCP phases `[MCP: service-name]`. Pre-authorize at plan time via `"go auto, approve MCP: X, Y"`. Mid-flow: pause before each MCP phase unless pre-authorized.

---

## Heartbeat Setup

The tend watchdog runs on an OS-level schedule so it can't be forgotten. Install once per machine (not per project):

```bash
# Create the launchd plist
cat > ~/Library/LaunchAgents/com.orchestrate.tend.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.orchestrate.tend</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/claude</string>
    <string>-p</string>
    <string>tend</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>WorkingDirectory</key>
  <string>/Users/haimengzhou/apps</string>
  <key>StandardOutPath</key>
  <string>/Users/haimengzhou/apps/ai-console/.orchestrate/logs/heartbeat.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/haimengzhou/apps/ai-console/.orchestrate/logs/heartbeat-err.log</string>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
EOF

# Load it
launchctl load ~/Library/LaunchAgents/com.orchestrate.tend.plist
```

To run tend manually at any time: type `tend` in any session.
To unload: `launchctl unload ~/Library/LaunchAgents/com.orchestrate.tend.plist`

**Note:** The heartbeat runs `tend` from `/Users/haimengzhou/apps` — the top-level apps directory. Tend scans for `.orchestrate/` directories one level deep and processes each project's registry in one pass. For a project-specific tend, `cd` into the project and type `tend` manually.

---

## Quick Reference

```bash
# New task
/task-orchestrate "refactor auth in gjw-web-fe to use JWT"

# Resume
/task-orchestrate resume

# Run watchdog manually
/task-orchestrate tend

# Drop a task into the inbox — use structured format for best results
cat > .orchestrate/inbox/rate-limit.md << 'EOF'
# Add rate limiting to all API endpoints

## Goal
Add per-IP rate limiting (100 req/min) to every route in src/routes/. Return 429 with Retry-After header on breach.

## Context
No rate limiting exists today. The express app entry point is src/app.ts. We use express-rate-limit in ads_rate_limit already — same pattern applies here.

## Acceptance Criteria
- All routes return 429 after 100 req/min per IP
- Retry-After header set correctly
- Unit tests cover the limit boundary
EOF

# Check project status
cat .orchestrate/project.md

# See all active tasks
ls .orchestrate/tasks/

# Activity log
tail -f .orchestrate/logs/heartbeat.log
```
