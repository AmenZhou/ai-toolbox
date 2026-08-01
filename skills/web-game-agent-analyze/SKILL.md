---
name: web-game-agent-analyze
description: Run a Playwright JSONL game agent headlessly, parse the session log for bugs, balance, UX, and fun issues, update agent memory, apply targeted fixes, and commit. Use for any web game with ai-agent/agent.js (run-a-hotel, jet-pilot-simulator, sky-force-reloaded, similar). Invoke from the game project root. Also matches /hotel-agent-analyze.
version: 3.0.0
---

# Web Game Agent: Run · Analyze · Memory · Fix

Runs the project's Playwright agent, parses structured JSONL logs into tagged issues, updates cross-session memory, fixes auto-eligible bugs, and proposes UX/fun backlog items.

**Requires:** `ai-agent/agent.js` writing JSONL to `ai-agent/logs/run-*.jsonl` with at least `session_start`, `tick`, `action`, `session_end`. v3 games also emit `event` records and richer `session_end` fields.

---

## Phase 0 — Detect profile and verify root

Run from the **game project root** (where `ai-agent/` lives).

### Auto-detect profile

| Profile | Marker files | Dev server | Default run |
|---------|--------------|------------|-------------|
| `run-a-hotel` | `grand_hotel_blueprint.html`, `js/game-state.js` | `file://` | `--turns 20 --tick 4000` |
| `jet-pilot-earth` | `earth.html`, `src/earth/main.js` | `npm run dev` → `:5173` | `--earth --heuristic --turns 90 --tick 500` |
| `jet-pilot-arcade` | `jet_pilot_simulator.html`, `js/simulation.js` | HTTP server | `--heuristic --turns 90 --tick 500` |
| `sky-force-reloaded` | `sky_force_reloaded.html`, `js/game.js` | `file://` | `--heuristic --stage --stage-id 2 --turns 200 --tick 350` |

```bash
ls ai-agent/agent.js ai-agent/logs 2>/dev/null
```

If `ai-agent/agent.js` is missing, abort: `No ai-agent found — run from a project with ai-agent/agent.js.`

Start any required dev server **before** Phase 1 (check project `README.md`).

### CLI args (user overrides; profile defaults)

Parse args from the user's message; fall back to profile defaults above.

| Flag | Purpose |
|------|---------|
| `--headless` | Always in Phase 1 analyze loop |
| `--turns N` / `--tick MS` | Session length |
| `--heuristic` / `--model` | Move picker |
| `--update-memory` | After run: `memory/update-from-log.js` |
| `--tune-after` | After run: `tune.js` |

---

## Phase 1 — Run agent

From project root:

```bash
node ai-agent/agent.js --headless --turns <N> --tick <tick_ms> [profile flags] 2>&1
```

**Profile command templates:**

```bash
# run-a-hotel
node ai-agent/agent.js --headless --turns <N> --tick <tick_ms> --model <claude|openai|openai-mini>

# jet-pilot-simulator (Earth)
node ai-agent/agent.js --earth --heuristic --headless --turns <N> --tick <tick_ms>

# sky-force-reloaded (pilot)
node ai-agent/agent.js --heuristic --headless --stage --stage-id 2 --turns 200 --tick 350
```

Capture `[logger] Writing to <path>`. Fallback:

```bash
ls -t ai-agent/logs/run-*.jsonl | head -1
```

**Report to user:** log path, turns, `session_end` present, profile outcome.

| Profile | Primary outcome |
|---------|-----------------|
| `run-a-hotel` | Final `cash` |
| `jet-pilot-earth` | `flight.agl`, crashes |
| `jet-pilot-arcade` | `mission.phase` |
| `sky-force-reloaded` | `stageCleared`, `finalRunStars`, `sectionsReached`, `bossTicks` |

---

## Phase 2 — Log analysis

Prefer the structured analyzer when present:

```bash
node ai-agent/analyze-report.js --log <path> [--write] [--out report.md]
```

Otherwise read JSONL manually. Group by `type`: `session_start`, `tick`, `event`, `action`, `session_end`, errors.

### Issue tags

| Tag | Auto-fix? | Typical signals |
|-----|-----------|-------------------|
| `[BUG]` | Yes | `page_error`, missing `session_end`, economy broken |
| `[AGENT]` | Yes | action spam, never reaches boss, excessive hits |
| `[BALANCE]` | Propose | high score, no stage clear |
| `[UX]` | Propose → `backlog.md` | confusing star economy, HUD gaps |
| `[FUN]` | Propose → `backlog.md` | section stall >25 ticks |
| `[ECON]` | Propose → `backlog.md` | runStars flat while score rises |
| `[RESEARCH]` | Propose → `backlog.md` | gap vs reference brief |

Rules live in `ai-agent/lib/issue-tags.js` (Sky Force profile implemented; extend for other games).

### Universal metrics

- Action distribution; flag `wait` > 30%
- Max consecutive identical action >5 (spam) or >20 (stuck)
- `page_error` / `console_error` counts

### Profile-specific metrics

#### `sky-force-reloaded`

| Metric | Rule |
|--------|------|
| Run stars trajectory | Flat >10 ticks while bullets active → `[ECON]` |
| Section progress | Same `section` >25 ticks → `[FUN]` |
| Score vs runStars | Score up, runStars flat → `[ECON]` or `[BUG]` |
| Boss reach | `bossTicks` = 0 in stage mode → `[AGENT]` |
| Stage clear | `stageCleared` false but high score → `[BALANCE]` |
| Death | `event:death` or `session_end.deathCause` → `[AGENT]` + playbook update |

#### `run-a-hotel` / `jet-pilot-*`

(See v2 metrics — unchanged.)

### Analysis report template

Output of `analyze-report.js` matches:

```markdown
## Agent Session Analysis — <log filename>
**Profile:** <profile> | **Turns:** N | **session_end:** yes/no

### Outcome
### Action Distribution
### Errors
### Issues Found
- [TAG] <description> — <evidence>
```

Only report issues supported by log data.

---

## Phase 2b — Web research brief (optional)

When `[UX]` / `[FUN]` / `[RESEARCH]` issues exist, or user asks:

```bash
node ai-agent/research/fetch-brief.js --profile sky-force-reloaded [--topic HUD]
```

- **Reference only** — patterns, not copyrighted assets
- Attach relevant brief rows to `ai-agent/backlog.md` as `[RESEARCH]` items
- Cached briefs live in `ai-agent/research/<profile>.md`

---

## Phase 3 — Fix vs propose

**Auto (default):** `[BUG]`, `[AGENT]` strategy bugs, `tune.js` threshold adjustments

**Propose only:** `[UX]`, `[FUN]`, `[ECON]`, `[RESEARCH]`, most `[BALANCE]` → append to `ai-agent/backlog.md`

**Never auto:** asset downloads, major economy overhauls without explicit approval

### Fix targets by profile

| Profile | Game source | Agent source |
|---------|-------------|--------------|
| `run-a-hotel` | `js/game-state.js`, `js/ui.js` | `ai-agent/agent.js`, `lib/heuristic.js` |
| `jet-pilot-earth` | `src/earth/*.js` | `ai-agent/agent.js` |
| `jet-pilot-arcade` | `js/simulation.js`, `js/physics.js` | `ai-agent/agent.js` |
| `sky-force-reloaded` | `js/game.js`, `js/main.js`, `js/player.js` | `ai-agent/lib/heuristic.js`, `memory/playbook.md` |

```bash
node --check ai-agent/agent.js
node --check <edited game files>
```

Re-run Phase 1 after critical fixes.

---

## Phase 4 — Memory update

After each analyze pass (or via `--update-memory` on agent run):

```bash
node ai-agent/memory/update-from-log.js --log <path> [--backlog]
```

Writes:
- `memory/metrics-history.jsonl` — compressed run metrics
- `memory/playbook.md` — auto-learned failure modes
- `backlog.md` — when `--backlog` or `--write` on analyze-report

Before runs, agent loads `playbook.md` + `stage-notes.json` into heuristic context (Sky Force).

---

## Phase 5 — Verify

Compare latest run to prior entries in `metrics-history.jsonl`:

- `stageCleared`, `finalRunStars`, `sectionsReached`, `hitsTaken` trending up
- Issue counts for `[AGENT]` / `[ECON]` trending down

Extended loop:

```bash
node ai-agent/improve-loop.js --headless --generations 3
```

---

## Phase 6 — Commit

Only when the user asked to commit.

```bash
git add <only modified files>
git commit -m "fix: <profile> agent analysis — <summary>"
```

---

## Autonomy defaults

| Action | Default |
|--------|---------|
| Bug / agent fixes | Auto |
| UX / fun / research | Backlog |
| Memory + metrics | Auto |
| Web assets | Reference only, no downloads |
| Pilot scenario (SF) | Stage 2, 200 turns, tick 350 |

---

## Headed vs headless

- **Analyze loop:** always `--headless`
- **User demo:** omit `--headless` only when they want to watch

---

## Adding a new game profile

1. Rich JSONL schema (`tick`, `event`, `session_end` extras)
2. Row in Phase 0 profile table
3. Metrics in `lib/issue-tags.js`
4. Optional `research/<profile>.md`
5. Fix targets in Phase 3 table
