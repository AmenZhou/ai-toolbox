---
name: ticket-planning
description: This skill should be used when the user asks to "write tickets", "create tickets", "refine tickets", "add ACs", "write acceptance criteria", "add a test plan", "flesh out a ticket", or wants to produce well-structured engineering tickets from a spec, plan, or notes. Produces tickets with Description, Acceptance Criteria, Open Questions, Design, Implementation Plan, and Test Plan sections.
version: 1.0.0
---

# Ticket Planning

Given a spec, plan doc, task list, or rough notes, produce well-structured engineering tickets ready to be picked up by a developer.

---

## Pre-flight

Before writing any tickets:
- Read the source document (spec, plan, test plan, etc.) fully
- Identify the sections or work areas that map to discrete, independently-completable units of work
- Note: one ticket = one unit of work that a single engineer can complete and close

---

## Ticket format

Each ticket must have all 6 sections in this order:

### [ID] — [Short title]

**Description**
What needs to be done and why. Include: context, scope, relevant data/counts, CLI interfaces, naming conventions, or constraints. Keep it self-contained — a reader should not need to open another doc to understand the task.

**Acceptance Criteria**
Checkbox list. Each AC must be:
- Specific and measurable (not "it works")
- Independently verifiable (someone other than the author can check it)
- Scoped to this ticket only (no cross-ticket ACs)

**Open Questions**
Blockers and unresolved decisions that must be answered before the ticket can be closed. If none, write "None."

**Design**
Technical approach: architecture decisions, data model choices, key constraints, libraries/patterns to use, and what NOT to do. If this is a discovery/investigation ticket, describe how to find the answer (what to look at, who to ask).

**Implementation Plan**
Ordered numbered steps for executing the ticket. Should be concrete enough for an engineer to follow without re-reading the description. Include: what to create/modify, what to run, what to check at each step.

**Test Plan**
Step-by-step verification that the ticket's work is correct. Include: SQL queries, CLI commands, API calls, or manual checks. Specify exact expected values where possible.

---

## Output rules

- Use ticket IDs that are meaningful to the work area (e.g. DS-1, K6-1, INFRA-1)
- Write descriptions that are self-contained — no "as described in the plan" references
- ACs must be checkboxes (`- [ ]`)
- Open Questions must be a bulleted list; write "None" if there are no blockers
- Implementation Plan must be a numbered list
- Test Plan must be specific: prefer `SELECT count(*) = X` over "verify count is correct"
- Note dependencies between tickets (e.g. "Blocked by DS-1")
- If a ticket is a discovery/investigation (no code output), the Implementation Plan describes the investigation steps and the Test Plan describes how to confirm the finding is documented and signed off
- **Count-based ACs must be derived, never guessed:** any AC that hard-asserts a count (`ls dir/*.html | wc -l == 11`, "should be N files", "exactly N rows") must be computed by *enumerating* the specific artifacts the ticket names — existing baseline + to-be-created — and asserting their sum. Cross-check `existing + new == asserted` before emitting the AC (this catches off-by-one totals). If the baseline count is unknown, don't guess it — make it an Open Question / discovery ticket and assert the sum once resolved.
- **Executor note for literal/numeric ACs (reconcile-and-document):** when a count/literal AC conflicts with verified project reality at execution time, the executor should *reconcile and document* — state the correct value with evidence (e.g. the actual `wc -l` output) — rather than fail the phase or silently pass on the wrong number.

---

## Refinement (existing tickets)

When asked to refine existing tickets:
1. Check whether all 6 sections are present — add any missing ones
2. Review ACs: rewrite vague ones, add missing ones, remove duplicate ones
3. Review Open Questions: promote any unresolved decisions embedded in Description to this section
4. Review Design: extract implementation-specific steps from Description into Implementation Plan
5. Review Test Plan: replace vague verification steps with specific commands/queries
6. Do not change the ticket's scope or ID
