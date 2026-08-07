---
name: next-orch-task
description: Auto-pick the next executable task from the orchestrate registry, considering dependencies and task urgency. Scans .orchestrate/project.md for eligible tasks (pending status with met dependencies), recommends the highest-priority task, and explains why it is next.
version: 1.0.0
---

# next-orch-task

Scan the orchestrate registry (`.orchestrate/project.md`) and recommend the next executable task to dispatch, considering dependency chains and task urgency.

This skill helps operators quickly identify which task to work on next without manually reviewing the entire registry.

## Quick Usage

```bash
# Show next recommended task
next-orch-task

# Show with verbose reasoning
next-orch-task --verbose

# Show multiple recommendations
next-orch-task --limit 3

# JSON output for dashboard/CLI integration
next-orch-task --json
```

## Invocation Modes

```bash
next-orch-task [OPTIONS]
```

**Options:**
- `--root <PATH>` (optional): Project root (default: current directory if it contains `.orchestrate/`, else `/Users/haimengzhou/apps/ai-console`)
- `--include-gated` (flag): Include gated tasks in recommendations (default: prioritize auto tasks)
- `--verbose` (flag): Show all skipped candidates with detailed reasons (default: quiet, show only recommended + summary)
- `--json` (flag): Output as JSON instead of human-readable format
- `--limit <N>` (optional): Show top N recommendations instead of 1 (default: 1)

**Environment Variables:**
- `ORCHESTRATE_ROOT`: Override default root path
- `ORCH_PICK_VERBOSE`: Set to `1` to enable verbose mode by default

## Algorithm

The skill implements the complete task-picking algorithm specified in `reports/orch-pick-inv_spec.md`:

### Candidate Selection
A task is a candidate for picking if it meets ALL criteria:
1. Status is `pending` (not `running`, `complete`, `needs_human`, `awaiting_go`, or `blocked`)
2. No unmet cross-task dependencies (runs `check-depends-on.sh` with exit 1 meaning clear)
3. Task file `.orchestrate/tasks/<ID>.md` exists and is readable
4. Registry row is well-formed (awk NF==8)

### Prioritization
When multiple candidates exist:
- **Tier 1:** Tasks with status `needs_human` (human-blocking; highest urgency)
- **Tier 2:** Tasks with `mode: auto` (dispatchable immediately)
  - Sorted by: phase ASC, last_activity ASC, id ASC
- **Tier 3:** Tasks with `mode: gated` (awaiting human approval)
  - Same ordering within tier
- **Tiebreaker:** Registry ID (alphabetical) for determinism

### Validation Checks
Before recommending a task, the skill performs:
1. **Dependency Lookup** — Run `check-depends-on.sh <ROOT> <ID>` to check for blocking
2. **Status Gates** — Must be `pending`; reject other statuses
3. **File Existence** — Task file must exist and be readable
4. **Registry Row Format** — Exactly 6 columns (awk NF==8)

## Output Formats

### Recommended Task (Human-Readable, Default)

When a task is recommended:
```
RECOMMENDED TASK
════════════════════════════════════════

ID:       20260804-inbox-ADE5
Title:    ORCH-PICK-INV — Design auto-next-task skill
Mode:     auto
Phase:    1 / 1
Status:   pending
Posted:   2026-08-04T12:30:00Z (age: 4h 23m)

RATIONALE
─────────
✓ Status is pending (ready to dispatch)
✓ No cross-task dependencies or dependencies met
✓ Task file exists and is readable
✓ Mode is auto (can dispatch immediately)
✓ Highest priority in queue

REGISTRY STATUS
───────────────
Total tasks: 142
  ├─ complete: 121
  ├─ running: 0
  ├─ pending: 3
  ├─ needs_human: 2
  ├─ awaiting_go: 0
  └─ blocked: 0
```

### Blocked/No Executable Tasks Case

When all pending tasks are blocked:
```
NO EXECUTABLE TASKS
═══════════════════

All pending tasks are blocked by unmet dependencies.

PENDING SUMMARY
───────────────
Total pending tasks: 2
- Blocked by dependencies: 2
- Auto-dispatchable: 0
- Gated (awaiting approval): 0

BLOCKED TASKS
─────────────
Task: 20260804-inbox-90DA (CH-AUG-VERIFY-2)
  Blocked by: 20260801-inbox-720E (status: awaiting_go)
```

### JSON Output

With `--json`:
```json
{
  "success": true,
  "recommended": [
    {
      "id": "20260804-inbox-ADE5",
      "mode": "auto",
      "phase": 1
    }
  ],
  "registry_status": {
    "total": 142,
    "complete": 121,
    "pending": 3,
    "needs_human": 2,
    "awaiting_go": 0
  }
}
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success; task recommended or status reported |
| 1 | No executable tasks available (not an error) |
| 2 | Registry/root path invalid or missing `.orchestrate/project.md` |
| 3 | Malformed registry or unreadable task files |

## Examples

### Show Next Recommended Task

```bash
$ next-orch-task
RECOMMENDED TASK
════════════════════════════════════════

ID:       20260804-inbox-ADE5
...
```

### Show With Detailed Reasoning

```bash
$ next-orch-task --verbose
# Shows all considered tasks and why each was skipped or selected
```

### JSON Output for Dashboard Integration

```bash
$ NEXT=$(next-orch-task --json | jq -r '.recommended[0].id')
$ echo "Next task: $NEXT"
Next task: 20260804-inbox-ADE5
```

### Specify Root Path

```bash
$ next-orch-task --root /path/to/project/root
```

## Related Files

- `.orchestrate/project.md` — Canonical task registry (read-only)
- `.orchestrate/tasks/{ID}.md` — Per-task metadata and logs (read-only)
- `.orchestrate/bin/check-depends-on.sh` — Dependency resolver (invoked by this skill)
- `reports/orch-pick-inv_spec.md` — Complete algorithm specification

## Integration

The skill can be invoked by:
- **CLI:** Directly via `next-orch-task [options]`
- **Dashboard:** `next-orch-task --json` feeds task recommendation widget
- **Launchd/Tend:** Invoked before dispatching to confirm next logical task
- **Orchestration:** Used by `/orch tend` to drive queue order

## Implementation Notes

- The script uses bash for maximum compatibility with orchestrate infrastructure
- Registry parsing uses AWK with pipe separator (`-F'|'`) for robust column extraction
- Timestamps are parsed with `date -j -f "%Y-%m-%dT%H:%M:%SZ"` (POSIX-compatible)
- Cross-task dependencies are resolved via external `check-depends-on.sh` for consistency
- All file I/O is read-only; no mutations to registry or task files
- Works completely offline; no API calls or external dependencies
