---
name: breakdown-to-inbox
description: Turn a job (spec, plan doc, rough notes, or the current conversation) into a set of well-structured, right-sized engineering tickets and stage them in the task-orchestrate inbox as individual task files — with dependencies and execution order. Use when the user says "break this down into tickets and push to inbox", "ticketize and queue these tasks", "plan and push to orchestrate", "turn this spec into inbox tasks", "decompose this into orchestrate tickets", or "split this work into inbox jobs". This is the multi-ticket decomposer + inbox writer. For refining ONE ticket (add ACs / a test plan / flesh out a single ticket) defer to the ticket-planning skill instead. Never starts execution — stages tasks and stops at the orchestrate go-gate.
version: 1.0.0
---

# breakdown-to-inbox

Decompose a job into multiple right-sized engineering tickets and write each as an individual
task file in the task-orchestrate inbox, so a downstream `tend` run can pick them up in
dependency order. This formalizes the manual "write N tickets to `.orchestrate/inbox/`" workflow.

**Scope boundary:** This skill *decomposes* a job into many tickets and *stages* them in the inbox.
To refine a single existing ticket (add ACs, write a test plan, flesh one out), use **ticket-planning**.
This skill reuses ticket-planning's 6-section format inline — it does not invoke it at runtime, so there
is no hard runtime dependency.

**HARD RULE:** This skill NEVER starts execution. It stages tasks and stops at "staged — awaiting go".
task-orchestrate always requires an explicit "go" from the human before any task runs. Do not run
`/orch`, `tend`, `drain-inbox.sh`, or any executor.

---

## Step 1 — Read the source job fully

The job is one of: a spec/plan doc (path or pasted), rough notes, or the current conversation.

- If a path or doc is given, read it completely before decomposing — do not skim.
- If the job is "the current conversation", treat everything discussed so far as the spec.
- Note: existing constraints, target repos/paths, data/counts, CLI interfaces, naming conventions,
  cluster/infra dependencies, and anything that affects gating (Step 5) or ordering (Step 4).

If the job is too vague to produce even two distinct tickets, ask ONE clarifying question and stop.
Otherwise proceed — resolve ambiguity with sensible defaults and record them in each ticket's
**Open Questions**.

## Step 2 — Decompose into right-sized units

Split the job into discrete tickets. **Right-sizing heuristic:**

- One ticket = one unit a single agent can finish in **one focused session**.
- **Split** when a ticket's Acceptance Criteria would exceed ~5, or the work spans multiple
  subsystems/repos, or it mixes investigation with implementation.
- **Merge** trivially-coupled fragments (e.g. "add field" + "add the one test for that field").
- Give each ticket a meaningful, work-area ID (e.g. `DS-1`, `P3-3`, `INFRA-1`) plus a short title.

## Step 3 — Apply the ticket-planning 6-section format (per ticket)

Each ticket MUST have a dependency header line + all 6 sections, in this order. Descriptions must be
**self-contained** — a reader must not need to open another doc to execute the ticket.

```markdown
### [ID] — [Short title]

**Target:** <repo path / branch / cluster, if applicable>
**Blocks:** <IDs this unblocks, or None>  ·  **Blocked by:** <IDs that must finish first, or None>

**Description**
What needs to be done and why. Include context, scope, relevant data/counts, CLI interfaces,
naming conventions, and constraints. Self-contained — no "as described in the plan" references.

**Acceptance Criteria**
- [ ] Specific and measurable (not "it works")
- [ ] Independently verifiable by someone other than the author
- [ ] Scoped to this ticket only (no cross-ticket ACs)

**Open Questions**
- Unresolved decisions/blockers. Write "None." if there are none. Record defaults you chose here.

**Design**
Technical approach: architecture/data-model decisions, libraries/patterns to use, and what NOT to do.
For an investigation ticket, describe how to find the answer (what to look at, who to ask).

**Implementation Plan**
1. Ordered, concrete steps — what to create/modify, what to run, what to check at each step.

**Test Plan**
Specific verification: exact commands / queries / API calls with expected values
(prefer `SELECT count(*) = X` over "verify count is correct").
```

## Step 4 — Compute dependencies + execution order

- For each ticket, fill **Blocked by:** (must finish first) and **Blocks:** (this unblocks) using
  data/artifact/precondition flow (e.g. "seed script" blocks "run that uses the seed").
- Detect cycles — if any exist, break them by re-splitting or merging tickets.
- Produce a **wave grouping**: Wave 1 = tickets with no unmet dependencies; later waves depend on
  earlier ones. This is the order a `tend` run should execute them in.

## Step 5 — Classify each ticket auto vs gated (risk-based, NOT location-based)

Default is **`mode: auto`** (write to inbox root). Mark a ticket **gated** only when it involves:

- destructive ops (`rm -rf`, `DROP`/`DELETE`/`TRUNCATE`, force-push),
- Kubernetes / infra mutations (`kubectl apply|scale|delete|patch|rollout`, `helm` mutate),
- `source: self` sensitive changes (editing the orchestrate control plane / this skill set),
- sending email / posting to Slack / triggering a deploy,
- or an explicit user request to gate it.

A gated ticket's Implementation Plan must stop at a review artifact (e.g. write the mutating command
to `/tmp/kube-cmd-*.sh`) and NOT execute the risky step — it awaits human approval.

## Step 6 — Write each ticket as an inbox task file

Resolve the inbox: from the project root, `<root>/.orchestrate/inbox/`. The default project root is the
current working directory's nearest ancestor containing `.orchestrate/` (for this console:
`/Users/haimengzhou/apps/ai-console/.orchestrate/inbox/`). Create `gated/` if a gated ticket needs it.

**Routing**
- `auto` ticket → `<root>/.orchestrate/inbox/<slug>-<ts>.md`
- `gated` ticket → `<root>/.orchestrate/inbox/gated/<slug>-<ts>.md`

**Filename:** `<kebab-slug>-YYYYMMDDTHHMMSS.md`
- `<kebab-slug>` = ticket ID + title, lowercased, spaces→`-`, non-alphanumerics stripped, ~40 chars.
- `YYYYMMDDTHHMMSS` = compact UTC timestamp, e.g. `20260628T035429`.

**Header** (at the very top, before the `# ` title) — these are the fields drain-inbox.sh reads:
```
mode: auto            # or "gated"
source: self          # who originated it (e.g. "self" for skill-staged, or a person/system)
triggered_by: <job-id-or-session-tag>   # provenance, e.g. 20260627-redis-p3prep-session
```
Then a blank line, then `# <ID> — <Short title>`, then the dependency header line + the 6 sections.

**Why these exactly:** drain-inbox.sh gates a file if it lives in `gated/`, OR has a `^mode: gated$`
line, OR is `source: self` AND its `## Goal`/`Description` mentions a risky op. So a correctly-routed
+ headered file is drop-in compatible — drain-inbox.sh registers it in `project.md` with the right mode
(auto→`pending`, gated→`awaiting_go`) and moves it to `processed/`.

## Step 7 — Print a summary table + dependency graph

Output to the console (do NOT write a separate report file):

```
── Staged tickets ─────────────────────────────────────────
| ID   | Title                         | mode  | depends on |
|------|-------------------------------|-------|------------|
| DS-1 | Seed MCC fixtures             | auto  | —          |
| P3-3 | Unit-cost ramp runbook        | auto  | DS-1       |
| P3-9 | Redis proxy restart (review)  | gated | —          |

Dependency waves (execution order):
  Wave 1:  DS-1, P3-9
  Wave 2:  P3-3   (after DS-1)
───────────────────────────────────────────────────────────
```

## Step 8 — STOP at the go-gate

Print exactly:
```
N ticket(s) staged in .orchestrate/inbox/ (and gated/ where applicable) — awaiting go.
Nothing has been executed. Reply "go" (or run /orch) to drain and start the run.
```
Then STOP. Do not drain, do not run tend, do not start any executor. The human owns the go decision.

---

## Worked example (dry — does NOT write to the real inbox)

**Job:** "We need the Phase 3 unit-cost ramp ready, but it depends on seeded MCC fixtures, and the
shared Redis is reporting no master, which blocks the cluster run."

This decomposes into 3 tickets. Two are shown in full below (both 6 sections + a dependency line);
the table/graph is in Step 7's format.

---

### DS-1 — Seed MCC fixture accounts for the ramp

**Target:** `/Users/haimengzhou/apps/ads-phase2-review` (branch `feature/phase-3-prep`)
**Blocks:** P3-3 (the ramp reads these accounts).  ·  **Blocked by:** None.

**Description**
The P3-3 unit-cost ramp queries a known set of MCC (manager) accounts that must exist before the run.
This ticket makes the seed script idempotent and verifies the expected account count exists, so the
scarce cluster window is not spent provisioning data. No cluster execution is in scope here.

**Acceptance Criteria**
- [ ] `scripts/seed_mcc_fixtures.sh` is idempotent (re-running does not create duplicates).
- [ ] After a run, `SELECT count(*) FROM mcc_accounts WHERE fixture = true` returns exactly 50.
- [ ] The seed count and how to re-run are documented in `reports/phase3/ds-1_fixtures.md`.

**Open Questions**
- Fixture count: defaulting to 50 (matches the documented ramp persona mix); confirm if the ramp needs more.

**Design**
- Pure data setup against the UAT DB; reuse the existing `seed_mcc_fixtures.sh` rather than a new path.
- Idempotency via `ON CONFLICT DO NOTHING`; do NOT delete existing non-fixture accounts.

**Implementation Plan**
1. Read `scripts/seed_mcc_fixtures.sh` and add an `ON CONFLICT DO NOTHING` guard on the insert.
2. Run the seed against UAT; capture stdout.
3. Verify the count query returns 50; record it in `reports/phase3/ds-1_fixtures.md`.

**Test Plan**
- Run the seed twice; second run prints `0 inserted`.
- `psql -c "SELECT count(*) FROM mcc_accounts WHERE fixture = true"` → `50`.
- `test -f reports/phase3/ds-1_fixtures.md`.

---

### P3-9 — Restart redis-proxy to clear "no master" (review-gated)

**Target:** `/Users/haimengzhou/apps/ads-phase2-review` · **Cluster:** `ads-uat-cluster-3`, ns `ads`
**Blocks:** P3-3 (cluster ramp needs a healthy Redis).  ·  **Blocked by:** None for the read-only
diagnosis; the fix step is human-gated (K8s mutation).

**Description**
The cluster ramp is blocked because redis-proxy (HAProxy) reports `redis_ha has no server available`,
while the redis data plane is healthy. The likely cause is stale backend endpoints after the redis pods
were recreated. This ticket confirms the root cause read-only and produces an operator-approved restart;
it does NOT execute the cluster mutation.

**Acceptance Criteria**
- [ ] redis-proxy backend endpoints are diffed against live `redis-0/1/2` pod IPs; stale-endpoint
  hypothesis confirmed or refuted in the task notes.
- [ ] A review script `/tmp/kube-cmd-redis-proxy-restart.sh` exists with `kubectl rollout restart
  deploy/redis-proxy -n ads` + pre/post diagnostics; the agent has NOT executed it.
- [ ] A post-fix verification plan is attached (re-run diagnose → no `no server available`).

**Open Questions**
- Is redis-proxy owned by us or the platform team? (If external, hand them the script instead of self-approving.)

**Design**
- Read-only kubectl for diagnosis only (`get pods -o wide`, `get deploy redis-proxy -o yaml`, `logs`).
- Honor the K8s safety rule: never run the mutating restart directly; write it to `/tmp/kube-cmd-*.sh`.
- Do NOT touch the Redis data plane (no `REPLICAOF NO ONE`) — a master already exists.

**Implementation Plan**
1. Run `diagnose_redis_uat.sh`; capture proxy/redis state.
2. Extract HAProxy backend IPs; diff against live pod IPs; record the verdict.
3. Write `/tmp/kube-cmd-redis-proxy-restart.sh` (pre-check, rollout restart, status, post-check). Do not execute.
4. Present findings + script for approval (gated).

**Test Plan**
- `diagnose_redis_uat.sh` → verdict prints the no-master alert BEFORE any fix.
- `test -f /tmp/kube-cmd-redis-proxy-restart.sh` and it contains the rollout-restart line.

---

(The third ticket, P3-3 — the ramp runbook — is `auto`, **Blocked by: DS-1, P3-9**, omitted here for brevity.)

**Summary + waves for this example:**
```
| ID   | Title                          | mode  | depends on |
|------|--------------------------------|-------|------------|
| DS-1 | Seed MCC fixture accounts      | auto  | —          |
| P3-9 | Restart redis-proxy (review)   | gated | —          |
| P3-3 | Unit-cost ramp runbook         | auto  | DS-1, P3-9 |

Wave 1:  DS-1, P3-9
Wave 2:  P3-3
```

**Closing step (always):**
```
3 ticket(s) staged in .orchestrate/inbox/ (P3-9 in gated/) — awaiting go.
Nothing has been executed. Reply "go" (or run /orch) to drain and start the run.
```

---

## Constraints

- Source of truth is `~/apps/ai-toolbox/skills/` — never edit `~/.claude/skills/` directly; run `sync.sh`.
- No live cluster, network, or MCP dependency — decomposition + staging are fully offline.
- Never start execution; always stop at the go-gate (Step 8).
- When unsure whether to gate, gate it — over-gating is safe, under-gating risks an unattended mutation.
