---
name: breakdown-to-inbox
description: Turn a job (spec, plan doc, rough notes, or the current conversation) into a set of well-structured, right-sized engineering tickets and stage them in the task-orchestrate inbox as individual task files — with dependencies and execution order. Use when the user says "break this down into tickets and push to inbox", "ticketize and queue these tasks", "plan and push to orchestrate", "turn this spec into inbox tasks", "decompose this into orchestrate tickets", or "split this work into inbox jobs". This is the multi-ticket decomposer + inbox writer. For refining ONE ticket (add ACs / a test plan / flesh out a single ticket) defer to the ticket-planning skill instead. Every unit of work becomes three chained tickets — Investigation/Plan → Implementation → Verification. Open questions answerable by investigation are resolved there; questions that need human judgment or access the agent doesn't have STOP the breakdown and ask the human. Never starts execution — stages tasks and stops at the orchestrate go-gate.
version: 2.0.0
---

# breakdown-to-inbox

Decompose a job into multiple right-sized units of work, and write each unit as **three chained
task files** — Investigation/Plan, Implementation, Verification — in the task-orchestrate inbox,
so a downstream `tend` run can pick them up in dependency order. This formalizes the manual
"write N tickets to `.orchestrate/inbox/`" workflow.

**Scope boundary:** This skill *decomposes* a job into many tickets and *stages* them in the inbox.
To refine a single existing ticket (add ACs, write a test plan, flesh one out), use **ticket-planning**.
This skill reuses ticket-planning's format inline as a base, plus one additional section (**Out of
Scope / Prohibitions**, Step 3) that ticket-planning does not have — it does not invoke ticket-planning
at runtime, so there is no hard runtime dependency and no requirement to keep the two skills' section
counts in sync.

**HARD RULE:** This skill NEVER starts execution. It stages tasks and stops at "staged — awaiting go".
task-orchestrate always requires an explicit "go" from the human before any task runs. Do not run
`/orch`, `tend`, `drain-inbox.sh`, or any executor.

**CORE PRINCIPLE — every unit gets Investigation/Plan → Implementation → Verification.** A unit of
work is never staged as a single implementation ticket. It is always staged as three tickets in a
chain: an **Investigation/Plan** ticket that researches the unit and writes a concrete plan artifact,
an **Implementation** ticket (Blocked by the investigation) that executes exactly that plan, and a
**Verification** ticket (Blocked by the implementation) that independently checks the result against
the investigation's acceptance criteria. See Step 2.

**CORE PRINCIPLE — research first, ask only when research can't resolve it.** When decomposition hits
an open question, try to resolve it inside the relevant unit's Investigation/Plan ticket (reading code,
docs, config — see Step 2). That covers most unknowns and needs no human input. But if a question
requires **human judgment, a product/business decision, credentials or access the agent doesn't have,
or an irreversible choice between materially different designs**, do **not** guess and do **not** stage
a ticket that papers over it — **STOP the breakdown and ask the human directly** (Step 1a). Resolve the
answer, then continue decomposing. The go-gate (Step 8) is still always required before execution, but
it is no longer the *only* point at which the human may be asked something.

---

## Step 1 — Read the source job fully

The job is one of: a spec/plan doc (path or pasted), rough notes, or the current conversation.

- If a path or doc is given, read it completely before decomposing — do not skim.
- If the job is "the current conversation", treat everything discussed so far as the spec.
- Note: existing constraints, target repos/paths, data/counts, CLI interfaces, naming conventions,
  cluster/infra dependencies, and anything that affects gating (Step 5) or ordering (Step 4).

## Step 1b — Scan the live control plane for overlapping work

Before finalizing any unit's dependencies (Step 4) or deciding whether Step 1a needs to ask the human,
scan for work that is already enqueued or in flight and might overlap this job. Scan **three sources**,
all relative to the canonical control plane root `/Users/haimengzhou/apps/ai-console`:

1. **`.orchestrate/project.md` non-terminal registry rows.** Parse the `## Task Registry` table; a row
   is "live" (in scope for overlap) iff its `status` column is one of `pending`, `running`, `awaiting_go`, `needs_human`
   — the same non-terminal set `check-depends-on.sh`'s gate and `churn-guard.sh`'s scope already use.
   `complete`, `failed`, `cancelled` rows are excluded — terminal, not a race risk. For each
   live row, also read `.orchestrate/tasks/<ID>.md` if it exists to pull its `**Target:**` line and
   `## Goal` text for heuristics 2–3 below — the registry table itself only carries `summary`, not target
   path or goal body.
2. **Undrained root inbox — `.orchestrate/inbox/*.md`.** Files not yet processed by `drain-inbox.sh` (no
   registry ID assigned yet). Exclude any file carrying a `deferred_at:` header — a deferred file was
   explicitly shelved by a human and should not gate new work.
3. **Undrained gated inbox — `.orchestrate/inbox/gated/*.md`.** Same file-shape and `deferred_at:`
   exclusion as (2); scanned separately only because it's a distinct directory, not because gated status
   changes the overlap logic.

`.orchestrate/inbox/processed/` is never scanned — historical record, already reflected in `project.md`
if it resulted in a live row, and irrelevant if terminal.

For each unit/ticket being staged, check it against each live source-item found above, in this priority
order:

1. **Explicit human-named ticket ID or title (highest confidence — hard-dependency candidate).** The
   source job text (the spec/notes/conversation being decomposed) literally names a registry task ID
   (matches `ID_SHAPE_RE` from `drain-inbox.sh`, i.e. `^[0-9]{8}-inbox-[0-9A-Za-z]+$`) or a work-area
   title/slug that exact- or prefix-matches a live row's `summary` column — reuse the same matching
   `resolve_title_ref()` (`drain-inbox.sh`) already performs, don't reinvent it.
2. **Target path overlap (medium confidence — soft conflict only, see Step 4).** The new ticket's
   `**Target:**` value (repo path / branch) exact- or prefix-matches a live task file's `**Target:**`
   value. Path overlap alone says nothing about whether the two touch the *same files* — too weak to
   wire as a hard block, strong enough to warn on.
3. **Shared resource keywords (lowest confidence — soft conflict only, see Step 4).** Quoted file/script
   basenames (e.g. `drain-inbox.sh`), table/service names, or a work-area prefix shared with a live
   row's summary (e.g. both start with `CH-`). A token match is a "these might be touching the same
   area" signal, not evidence of a real ordering dependency — false positives are expected and
   acceptable here, since this channel is print-only.

Heuristic 1 is deterministic and cheap; heuristics 2–3 are best-effort greps, not semantic analysis —
they exist to surface things for a human to notice, not to make autonomous blocking decisions. Carry the
resulting per-unit list of `(live_ref, kind: hard|soft, source: registry-id|inbox-basename,
matched_heuristic)` tuples forward to Step 4 and Step 7.

A heuristic-1 hard match found here can itself inform whether Step 1a needs to ask the human (e.g. "this
unit collides with an `awaiting_go` ticket someone else is mid-review on — do you want to wait, or
proceed and I'll wire the dependency?" is a legitimate Step 1a-shaped question) — this step only
surfaces the match, it does not itself decide whether to stop and ask.

## Step 1a — Stop and ask, but only when investigation genuinely can't resolve it

Most open questions belong inside a unit's **Investigation/Plan** ticket (Step 2) — they get answered
by reading code, docs, config, or existing data, with no human involved. Default to that path.

Only interrupt the breakdown and ask the human directly when a question is **not answerable by
investigation** — i.e. it requires:
- a **human judgment or product/business decision** (e.g. "should this feature be opt-in or default-on"),
- **credentials, access, or context the agent does not have** (e.g. a decision that lives in someone's
  head, a system the agent can't reach),
- a choice between **materially different, hard-to-reverse designs** where guessing wrong would mean
  redoing real work (not just re-running a script).

When that happens:
1. Stage whatever units/tickets are *not* blocked by the question (don't hold the whole job hostage
   to one unclear part).
2. Print the specific question(s) to the human, each with the options you see and your recommendation.
3. STOP — do not stage the blocked unit's tickets yet, do not proceed to Step 7/8 for the blocked
   portion. Wait for the human's answer, then resume decomposition for that unit only.

This is narrower than "ask about anything unclear" — a question you *could* answer yourself by reading
the repo is not a reason to stop. Reserve stopping for things only the human can actually settle.

## Step 2 — Decompose into right-sized units, each staged as three chained tickets

Split the job into discrete **units of work**. **Right-sizing heuristic:**

- One unit = one thing a single agent can implement in **one focused session**.
- **Split** when a unit's Acceptance Criteria would exceed ~5, or the work spans multiple
  subsystems/repos.
- **Merge** trivially-coupled fragments (e.g. "add field" + "add the one test for that field").
- Give each unit a meaningful, work-area ID (e.g. `DS-1`, `P3-3`, `INFRA-1`) plus a short title.

**Every unit becomes exactly three tickets, chained in this order:**

1. **`<ID>-INV` — Investigation/Plan.** Researches the unit and produces a concrete, written
   implementation plan artifact. This is where open questions get resolved (Step 1a) — by reading
   code/docs/config, not by guessing. Stays read-only / non-mutating: it investigates and plans, it
   does not ship the change.
2. **`<ID>-IMPL` — Implementation.** `Blocked by: <ID>-INV`. Executes *exactly* the plan the
   investigation ticket produced — it does not re-derive the approach. References the plan artifact
   by path instead of re-explaining the reasoning.
3. **`<ID>-VERIFY` — Verification.** `Blocked by: <ID>-IMPL`. Independently checks the implementation
   against the investigation ticket's Acceptance Criteria — re-runs tests, reviews the actual diff, and
   diffs the actual changed files against the investigation ticket's **Out of Scope / Prohibitions**
   list to confirm nothing on that list was touched. Written as if performed by someone other than the
   implementer: it must not simply trust the implementer's own claim of success.

This structure **replaces** the old conditional "research ticket" pattern — investigation is no longer
optional or reserved for materially-gating unknowns; every unit gets one. If a unit is truly trivial
(e.g. a one-line config change with an obvious, undisputed plan), the Investigation ticket's plan can be
short, but it still exists so Implementation and Verification have something concrete to point at.

A unit's **Investigation/Plan** ticket MUST:
- have **Acceptance Criteria** that are *a plan recorded in a concrete artifact* (e.g.
  `reports/<area>/<id>-inv_plan.md`) covering: the approach, files/commands involved, and the exact
  Acceptance Criteria the Implementation ticket must satisfy and the Verification ticket must check,
- name, in its **Design**, exactly where to look (files, dashboards, commands) to get any answers,
- if it hits a question it cannot resolve itself, follow Step 1a instead of guessing.

## Step 3 — Apply the ticket template format (per ticket)

Each ticket MUST have a dependency header line + all 7 sections, in this order. Descriptions must be
**self-contained** — a reader must not need to open another doc to execute the ticket (the Implementation
and Verification tickets should still point at the Investigation ticket's plan artifact for the full
rationale, but their own Description/AC/Implementation Plan/Test Plan must make sense standalone).

**Count-based acceptance criteria — derive, never guess.** Any AC that hard-asserts a count
(`ls web/*.html | wc -l == 11`, "should be N files", "exactly N rows") MUST be computed by
**enumerating the specific artifacts** the ticket itself names — existing baseline + to-be-created —
and asserting their sum. Never carry a standalone remembered/assumed total. Before emitting the AC,
run the self-consistency check `existing_count + new_count == asserted_total`; if it fails, fix the
number (this catches off-by-one totals at authoring time). If the baseline count is unknown, do not
guess it — make it the job of the unit's Investigation/Plan ticket and assert the sum once that lands.

**"0 failures" ACs — carve out install-integration tests.** Any AC that hard-asserts a blanket pass
across a ported, cloned, or newly-authored test suite ("every test file runs and reports 0 failures",
"all tests pass") MUST first check for tests that depend on live local state not guaranteed on a fresh
checkout — a running service, an installed binary, a loaded launchd/cron job, network/DB access, etc.
Either exclude those tests from the AC's scope explicitly (name the file(s)) or add a carve-out clause
to the AC text itself (e.g. "... 0 failures, excluding `test-launch-agent.js` which requires a live
local install"). Don't let a genuinely environment-dependent test masquerade as a regression later.

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

**Out of Scope / Prohibitions**
- Explicit boundary: files, systems, or behaviors this ticket must NOT touch, even if related or
  tempting to fix along the way while in the area.
- If nothing beyond the Acceptance Criteria's own boundary needs calling out, write "None beyond the
  Acceptance Criteria above." — do not leave this section blank or omit it.

**Open Questions**
- Unresolved decisions/blockers. Write "None." if there are none.
- If a question is answerable by investigation, it belongs in `<ID>-INV`, not here as a bare question.
- If a question needs the human (Step 1a), it must already be resolved before this ticket is staged —
  a staged ticket should never carry an unanswered human-judgment question.

**Design**
Technical approach: architecture/data-model decisions, libraries/patterns to use. (Negative constraints —
what NOT to touch — belong in **Out of Scope / Prohibitions** above, not here; do not duplicate them.)
For the Investigation/Plan ticket, describe how to find the answer (what to look at) and what the plan
artifact must contain. For Implementation, point at the plan artifact instead of re-deriving the approach.
For Verification, describe how to check independently (re-run tests, diff the actual changed files
against the Out of Scope / Prohibitions list) — not just re-trust the implementer.

**Implementation Plan**
1. Ordered, concrete steps — what to create/modify, what to run, what to check at each step.

**Test Plan**
Specific verification: exact commands / queries / API calls with expected values
(prefer `SELECT count(*) = X` over "verify count is correct"). For the Verification ticket this section
*is* most of the ticket's substance.
```

## Step 4 — Compute dependencies + execution order

- Within a unit, the chain is fixed: `<ID>-INV` blocks `<ID>-IMPL` blocks `<ID>-VERIFY`.
- Across units, fill **Blocked by:**/**Blocks:** using data/artifact/precondition flow. Point
  cross-unit dependencies at the specific stage that actually produces or needs the dependency —
  e.g. if unit B's plan depends on unit A's shipped change, `B-INV` is `Blocked by: A-IMPL` (not
  `A-VERIFY`, unless B genuinely needs A to be *verified* correct first, not just implemented).
- Detect cycles — if any exist, break them by re-splitting or merging units.
- Produce a **wave grouping**: Wave 1 = tickets with no unmet dependencies (typically the `-INV`
  tickets of independent units); later waves depend on earlier ones. This is the order a `tend` run
  should execute them in. Waves will naturally interleave INV/IMPL/VERIFY stages across units.

**Structural marker for cross-ticket blockers (not just prose).** Whenever a ticket's **Blocked by:**
line names another ticket that is *also being staged in this same batch* (i.e. you know its exact
filename because you're writing it too), also emit a `blocked_by_ticket: <that other ticket's exact
filename, without .md>` header line on the blocked ticket (Step 6). This is what lets `drain-inbox.sh`
carry the dependency into the materialized task file's `depends_on:` field structurally — instead of
leaving `depends_on: none` with the ordering living only as prose inside `## Goal`/Description, which
a downstream `tend` run cannot act on. Emit the header in both cases: when the referenced ticket is part
of this same batch (using its exact filename, without `.md`), and when the blocker is an
already-registered ticket from a prior run (using its literal registry ID, e.g.
`blocked_by_ticket: 20260801-inbox-09AB`) — `resolve_depends_on()` Stage 2 in `drain-inbox.sh` (an
`ID_SHAPE_RE` pre-filter followed by an exact `registry_has_id()` match) now resolves this literal-ID
form against real prior-run registry rows, not just same-batch basenames. Only fall back to
`depends_on: none` with the ordering left in prose when you don't actually know the prior-run ticket's
registry ID.

**Live-overlap hard dependencies (from Step 1b).** When Step 1b found a heuristic-1 hard match against a
*live* (pre-existing, not same-batch) item, wire it using the **same** `blocked_by_ticket:` mechanism as
above, with the reference value depending on what the live overlap actually is:
- **Live overlap is a registry row (already has an ID).** Emit `blocked_by_ticket: <that row's real
  registry ID>` (e.g. `blocked_by_ticket: 20260801-inbox-8B12`). **This already resolves today** —
  `drain-inbox.sh`'s Stage 2 (`ID_SHAPE_RE` match + `registry_has_id()` exact check) was built for
  exactly this shape of reference; no further `drain-inbox.sh` change is needed.
- **Live overlap is an undrained inbox file (no ID yet).** Emit `blocked_by_ticket: <that file's
  basename, without .md>` — the same convention used above for a same-batch sibling. **Known,
  unclosed race window:** this only resolves via Stage 1 (`BLOCKED_BY_MAP`) if the pre-existing file and
  this ticket are drained in the *same* `drain-inbox.sh` invocation. If the pre-existing file was
  already drained in an earlier, separate run, its basename is gone from that later run's ephemeral
  `BLOCKED_BY_MAP`, it does not match `ID_SHAPE_RE` (an inbox basename isn't `YYYYMMDD-inbox-*`-shaped),
  and Stage 3's `resolve_title_ref()` matches against the registry's **title-derived `summary`**
  column, not a raw filename — so resolution can silently fall to `none`. Do not imply this reference
  form always resolves; state the caveat if surfacing it to a human.

Heuristic-2/3 soft conflicts from Step 1b are **never** wired into `blocked_by_ticket:` here — nor into
**Blocked by:** — a low-confidence match wired as a hard block risks stalling unrelated work behind a
false positive with no human ever prompted to un-stick it. Soft conflicts are carried to Step 7 only.

## Step 5 — Classify each ticket auto vs gated (risk-based, NOT location-based)

Default is **`mode: auto`** (write to inbox root). Gating is **risk-based** — it depends on what the
ticket *does*, not on who authored it. Mark a ticket **gated** only when its actual work involves:

- destructive ops (`rm -rf`, `DROP`/`DELETE`/`TRUNCATE`, force-push),
- Kubernetes / infra mutations (`kubectl apply|scale|delete|patch|rollout`, `helm` mutate),
- sending email / posting to Slack / triggering a deploy,
- or an explicit user request to gate it (an explicit `gate_reason:` line).

**`source: self` alone does NOT gate.** Editing the orchestrate control plane / this skill set (a
SKILL.md edit, a `bin/` script change, adding a test) is a reversible, locally-verifiable code change —
it is `mode: auto` unless its *work* hits one of the risky ops above or the user explicitly asks to gate
it. This mirrors the live `drain-inbox.sh` rule (risk-based, not source/location-based): a `source: self`
ticket with no risky op and no `gate_reason:` is registered `auto`/`pending`, and the inline critic +
the auto review/tests enforcement are the safety net for such code changes — not a human gate.

> **Do NOT write a `gate_reason:` line just because a ticket edits the control plane** — that forces a
> false gate (and a ticket that merely *mentions* a risky op inside a prohibition, e.g. "never force-push",
> must not be gated either; describe such constraints without spelling raw risky-op keywords where possible).

A gated ticket's Implementation Plan must stop at a review artifact (e.g. write the mutating command
to `/tmp/kube-cmd-*.sh`) and NOT execute the risky step — it awaits human approval.

**Per-stage gating within a unit.** Gate each stage independently based on what *it* does, not what
the unit as a whole does — an Investigation ticket is read-only and is almost never gated even when its
unit's Implementation is; a Verification ticket is also almost always `auto` (it observes/checks, it
doesn't mutate) unless the verification itself requires a risky op (rare). Only the `-IMPL` ticket
typically inherits the unit's real gating classification.

## Step 6 — Write each ticket as an inbox task file

Resolve the inbox: **always** the single live control plane —
`/Users/haimengzhou/apps/ai-console/.orchestrate/inbox/` — regardless of the current working directory.
This is the only inbox the running `tend`/`drain-inbox`/`monitor` (dashboard) launchd jobs watch (they all
run with `WorkingDirectory=/Users/haimengzhou/apps/ai-console`), so tickets written anywhere else are
orphaned and never picked up or shown. Do **not** walk up from cwd to a project-local `.orchestrate/`
(e.g. `sy_promotion_merchant_scraper/.orchestrate/`) — those are dormant. For a ticket that operates on a
*different* project's files, keep the inbox path as ai-console and make the file/script paths inside the
ticket **absolute** (point at the target repo). Create `gated/` if a gated ticket needs it.

**Routing** (`<root>` = `/Users/haimengzhou/apps/ai-console`)
- `auto` ticket → `<root>/.orchestrate/inbox/<slug>-<ts>.md`
- `gated` ticket → `<root>/.orchestrate/inbox/gated/<slug>-<ts>.md`

**Filename:** `<kebab-slug>-YYYYMMDDTHHMMSS.md`
- `<kebab-slug>` = ticket ID (including the `-inv`/`-impl`/`-verify` suffix) + title, lowercased,
  spaces→`-`, non-alphanumerics stripped, ~40 chars — e.g. `p3-3-inv-unit-cost-ramp-plan`.
- `YYYYMMDDTHHMMSS` = compact UTC timestamp, e.g. `20260628T035429`. Give each of a unit's three
  tickets a distinct timestamp (even a few seconds apart) so filenames never collide.

**Header** (at the very top, before the `# ` title) — these are the fields drain-inbox.sh reads:
```
mode: auto            # or "gated"
source: self          # who originated it (e.g. "self" for skill-staged, or a person/system)
triggered_by: <job-id-or-session-tag>   # provenance, e.g. 20260627-redis-p3prep-session
blocked_by_ticket: <value — see Step 4 for the three forms>
    # (a) a same-batch sibling's filename-without-.md — this ticket's Blocked by: line names another
    #     ticket being staged in THIS SAME batch (original form), OR
    # (b) a live prior-run registry task ID from Step 1b's heuristic-1 hard match — resolves today via
    #     drain-inbox.sh's Stage 2, OR
    # (c) a pre-existing undrained inbox file's basename from Step 1b's heuristic-1 hard match —
    #     resolves only if that file is drained in the same run as this ticket (race window, see Step 4)
```
Then a blank line, then `# <ID> — <Short title>`, then the dependency header line + the 7 sections.

**Why these exactly:** drain-inbox.sh gates a file if it lives in `gated/`, OR has a `^mode: gated$`
line, OR is `source: self` AND its `## Goal`/`Description` mentions a risky op. So a correctly-routed
+ headered file is drop-in compatible — drain-inbox.sh registers it in `project.md` with the right mode
(auto→`pending`, gated→`awaiting_go`) and moves it to `processed/`. It also resolves `blocked_by_ticket:`
(if present and the referenced ticket has already been registered earlier in the same drain batch) into
a real `depends_on:` ID on the materialized `.orchestrate/tasks/{ID}.md` — see Step 4.

## Step 7 — Print a summary table + dependency graph

Output to the console (do NOT write a separate report file). Every unit contributes three rows:

```
── Staged tickets ──────────────────────────────────────────────────
| ID          | Title                          | stage  | mode  | depends on   |
|-------------|--------------------------------|--------|-------|--------------|
| DS-1-INV    | Fixture count + seed plan      | inv    | auto  | —            |
| DS-1-IMPL   | Seed MCC fixture accounts      | impl   | auto  | DS-1-INV     |
| DS-1-VERIFY | Verify seeded fixtures         | verify | auto  | DS-1-IMPL    |
| P3-9-INV    | Diagnose redis-proxy no-master | inv    | auto  | —            |
| P3-9-IMPL   | Restart redis-proxy (review)   | impl   | gated | P3-9-INV     |
| P3-9-VERIFY | Confirm proxy healthy          | verify | auto  | P3-9-IMPL    |
| P3-3-INV    | Ramp runbook plan              | inv    | auto  | DS-1-VERIFY, P3-9-VERIFY |
| P3-3-IMPL   | Run unit-cost ramp             | impl   | auto  | P3-3-INV     |
| P3-3-VERIFY | Verify ramp results            | verify | auto  | P3-3-IMPL    |

Dependency waves (execution order):
  Wave 1:  DS-1-INV, P3-9-INV
  Wave 2:  DS-1-IMPL, P3-9-IMPL           (after their own -INV)
  Wave 3:  DS-1-VERIFY, P3-9-VERIFY       (after their own -IMPL)
  Wave 4:  P3-3-INV                       (after DS-1-VERIFY, P3-9-VERIFY)
  Wave 5:  P3-3-IMPL                      (after P3-3-INV)
  Wave 6:  P3-3-VERIFY                    (after P3-3-IMPL)
──────────────────────────────────────────────────────────────────────
```

**Live overlaps (from Step 1b).** If Step 1b found any soft conflicts (heuristics 2–3), print a second
block right after the table above — omit this block entirely when there are none:
```
⚠ Live overlaps (not blocked — for awareness only) ─────────────
| Unit ticket | Overlaps      | Status      | Heuristic     |
|-------------|---------------|-------------|---------------|
| P3-3-INV    | 20260628-inbox-9D5A | running | target-path   |
```
Note: the "depends on" column in the **Staged tickets** table above may now name a **pre-existing** live
registry ID or undrained-inbox basename (a Step 1b heuristic-1 hard match), not only a same-batch
sibling — hard matches are wired directly into that column, not into this separate soft-conflict block.

Then add a **Recommended next step** line (this is the "tell me what to do next" the human asked for) —
derived from the waves. Example:

```
Recommended next step: go — run Wave 1 (DS-1-INV + P3-9-INV). Both are read-only investigations that
produce plans for their unit's implementation; nothing mutates until Wave 2. P3-9-IMPL is gated — review
/tmp/kube-cmd-redis-proxy-restart.sh before approving the Redis mutation when Wave 2 reaches it.
```

## Step 8 — STOP at the go-gate

Print exactly:
```
N ticket(s) staged in .orchestrate/inbox/ (and gated/ where applicable) — awaiting go.
Nothing has been executed. Reply "go" (or run /orch) to drain and start the run.
```
Then STOP. Do not drain, do not run tend, do not start any executor. The human owns the go decision.
The skill's job is to research, stage, and *recommend* — not to ask the human a question to proceed
**at this stage**; any question that genuinely needed the human was already asked and resolved back in
Step 1a, before this point.

---

## Worked example (dry — does NOT write to the real inbox)

**Job:** "We need the Phase 3 unit-cost ramp ready, but it depends on seeded MCC fixtures, and the
shared Redis is reporting no master, which blocks the cluster run."

This decomposes into 3 units → 9 tickets. The `DS-1` unit is shown in full below (all three tickets,
each 7 sections + a dependency line); `P3-9` and `P3-3` are summarized in Step 7's table format.

---

### DS-1-INV — Resolve MCC fixture count/persona mix and write the seed plan

**Target:** `/Users/haimengzhou/apps/ads-phase2-review` (branch `feature/phase-3-prep`)
**Blocks:** DS-1-IMPL.  ·  **Blocked by:** None.

**Description**
The seed step needs to know how many MCC fixture accounts the unit-cost ramp exercises, which persona
mix, and the exact idempotent seeding approach. This ticket resolves all of that read-only from the
ramp spec, the existing persona config, and the current seed script, and writes one authoritative plan
that DS-1-IMPL executes without re-deriving anything.

**Acceptance Criteria**
- [ ] `reports/phase3/ds-1-inv_plan.md` states the required fixture count and persona breakdown, citing
  the ramp spec section / persona config file + line.
- [ ] The plan names the exact idempotency mechanism (`ON CONFLICT DO NOTHING` on the existing
  `scripts/seed_mcc_fixtures.sh`) and the exact verification query DS-1-IMPL and DS-1-VERIFY must both use.
- [ ] If the spec is silent on the count, the plan states the chosen default and why.

**Out of Scope / Prohibitions**
- Do not modify `scripts/seed_mcc_fixtures.sh` or any data — this ticket is read-only planning.
- Do not seed fixtures into any environment (UAT or otherwise) — that execution is DS-1-IMPL's job.

**Open Questions**
- None — this ticket exists to remove the open question, not to carry one.

**Design**
- Read-only: grep the ramp spec and `config/personas.yml`; do NOT modify data or run the seed here.
- Where to look: `docs/phase3/unit_cost_ramp.md` (persona mix), `config/personas.yml` (counts per persona),
  `scripts/seed_mcc_fixtures.sh` (current seed logic, to plan the idempotency guard against it).

**Implementation Plan**
1. Read the ramp spec + persona config; extract the required fixture count and per-persona split.
2. Read `seed_mcc_fixtures.sh`; decide exactly how the idempotency guard fits into it.
3. Write the plan (count + breakdown + source citations + exact guard + verification query) to
   `reports/phase3/ds-1-inv_plan.md`.

**Test Plan**
- `test -f reports/phase3/ds-1-inv_plan.md` and it contains an explicit integer fixture count.
- The doc cites at least one source file:line and states an exact `SELECT count(*) ...` verification query.

---

### DS-1-IMPL — Seed MCC fixture accounts per the DS-1-INV plan

**Target:** `/Users/haimengzhou/apps/ads-phase2-review` (branch `feature/phase-3-prep`)
**Blocks:** DS-1-VERIFY.  ·  **Blocked by:** DS-1-INV.

**Description**
Execute exactly the plan in `reports/phase3/ds-1-inv_plan.md` — add the idempotency guard it specifies
to `scripts/seed_mcc_fixtures.sh` and run it against UAT. No cluster execution is in scope here.

**Acceptance Criteria**
- [ ] `scripts/seed_mcc_fixtures.sh` has the idempotency guard from `ds-1-inv_plan.md` (re-running does
  not create duplicates).
- [ ] After a run, the verification query from `ds-1-inv_plan.md` returns the count that document specifies.
- [ ] Run output is captured in `reports/phase3/ds-1-impl_run.md`.

**Out of Scope / Prohibitions**
- Do not modify `config/personas.yml` or any persona source config — only apply the idempotency guard
  `ds-1-inv_plan.md` specifies to `scripts/seed_mcc_fixtures.sh`.
- Do not run the unit-cost ramp or touch cluster execution — that is P3-3's scope, not DS-1's.

**Open Questions**
- None — fixture count and approach are fixed by `ds-1-inv_plan.md`.

**Design**
- Follow `ds-1-inv_plan.md` exactly; do not re-derive the approach or second-guess the resolved count.

**Implementation Plan**
1. Read `reports/phase3/ds-1-inv_plan.md` for the target count `N` and the guard to add.
2. Add the guard to `scripts/seed_mcc_fixtures.sh`.
3. Run the seed against UAT; capture stdout to `reports/phase3/ds-1-impl_run.md`.

**Test Plan**
- Run the seed twice; second run prints `0 inserted`.
- Run the verification query from `ds-1-inv_plan.md` → returns `N`.

---

### DS-1-VERIFY — Independently verify the seeded fixtures

**Target:** `/Users/haimengzhou/apps/ads-phase2-review` (branch `feature/phase-3-prep`)
**Blocks:** P3-3-INV.  ·  **Blocked by:** DS-1-IMPL.

**Description**
Independently confirm DS-1-IMPL actually did what it claims — do not trust `ds-1-impl_run.md`'s own
output. Re-derive the count from the database, re-check idempotency, and confirm nothing outside scope
was touched.

**Acceptance Criteria**
- [ ] Independently re-running the verification query from `ds-1-inv_plan.md` returns `N`.
- [ ] Re-running `seed_mcc_fixtures.sh` a third time still inserts `0` rows.
- [ ] `mcc_accounts` rows with `fixture = false` are unchanged in count from before DS-1-IMPL started.

**Out of Scope / Prohibitions**
- Do not modify `scripts/seed_mcc_fixtures.sh` or insert/delete any rows — this ticket only observes
  and queries.
- Do not re-scope the check beyond DS-1-IMPL's declared change — no re-litigating DS-1-INV's fixture
  count or persona mix here.

**Open Questions**
- None.

**Design**
- Independent check: query the DB directly rather than reading `ds-1-impl_run.md`'s claimed numbers.

**Implementation Plan**
1. Run the verification query from `ds-1-inv_plan.md` directly against UAT.
2. Re-run the seed script once more; confirm `0 inserted`.
3. Diff the non-fixture account count against the pre-DS-1-IMPL baseline.
4. Record the verdict in `reports/phase3/ds-1-verify_result.md`.

**Test Plan**
- `psql -c "<verification query>"` → `N`.
- `bash scripts/seed_mcc_fixtures.sh` → `0 inserted`.
- Non-fixture account count unchanged vs. baseline.

---

`P3-9` (redis-proxy fix) and `P3-3` (the ramp run) follow the same INV → IMPL → VERIFY pattern — see
the Step 7 table above for their full 9-ticket dependency graph. `P3-9-IMPL` is the only `gated` ticket
in this job (it's the one that actually runs `kubectl rollout restart`); its `-INV` and `-VERIFY` are
both read-only and stay `auto`.

**Closing step (always):**
```
9 ticket(s) staged in .orchestrate/inbox/ (P3-9-IMPL in gated/) — awaiting go.
Nothing has been executed. Reply "go" (or run /orch) to drain and start the run.
```

### Variant: when Step 1a triggers instead

If, while writing `P3-3-INV`, the target request rate for the ramp turned out to be undocumented and
undiscoverable in the repo (a product/SLA decision, not a research question), the skill would stop
there instead of guessing:

```
Open question — needs your input before I can stage P3-3:

  P3-3 (unit-cost ramp) needs a target request rate to size the ramp steps. The ramp spec doesn't
  state one and it isn't derivable from existing config — this is a product/SLA decision, not
  something I can research my way to.

  Options: (a) match last quarter's observed peak (~4.2k rps), (b) use a new SLA target if one exists
  elsewhere, (c) you give me a number.
  Recommendation: (a) — grounded in real data, and the spec gives no other signal.

DS-1 (3 tickets) and P3-9 (3 tickets) are staged and ready — see the table above.
P3-3 is held until you answer; I'll stage its 3 tickets right after.
```

---

## Constraints

- Source of truth is `~/apps/ai-toolbox/skills/` — never edit `~/.claude/skills/` directly; run `sync.sh`.
- No live cluster, network, or MCP dependency — decomposition + staging are fully offline.
- Never start execution; always stop at the go-gate (Step 8).
- Gate on the **actual risky op**, not on authorship or caution. Over-gating is NOT free — it stalls
  safe, auto-runnable work behind a needless human approval and pollutes the gated queue. Gate only when
  a ticket's work genuinely hits a risky op (Step 5) or the user explicitly asks; a reversible code/
  test/docs change (including `source: self`) stays `auto`. Reserve gating for real unattended-mutation risk.
- **Every unit is three tickets, always.** Never stage a bare implementation ticket without its
  Investigation/Plan and Verification siblings (Step 2) — even for units that look trivial.
- **Research first, ask only when research can't resolve it.** A question answerable by reading code/
  docs/config belongs in the unit's `-INV` ticket, not a prompt to the human. A question that needs
  human judgment, access the agent lacks, or a hard-to-reverse design call STOPS the breakdown for that
  unit and asks the human directly (Step 1a) — do not stage a ticket that guesses at it. Units not
  blocked by the question still get staged and the go-gate summary still applies to them.
