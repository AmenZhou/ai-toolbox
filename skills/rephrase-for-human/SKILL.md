---
name: rephrase-for-human
description: Rewrite an agent-generated question, status update, or approval request into plain language a person can answer or act on in seconds. Strips internal detail (tool names, IDs, file paths, state-machine jargon), leads with the decision or the news, and offers a recommended default. Use when the user says "rephrase this for a human", "make this question readable", "explain what the agent is asking", "plain English", "humanize this", or when you are about to ask the user a question or report status after long agentic work.
---

# Rephrase for Human

Turn agent-speak into something a busy person can answer without opening a log.

**Core question:** *What does this person need to decide or know, and what is the least they must read to do it?*
Agent output optimises for completeness and traceability. Human-readable output optimises for the reader's next move.

## When to use

- A subagent, ticket, log, or tool result produced a question or statement the user must read.
- You are about to ask the user something after long agentic work (reader has lost context).
- The user pastes agent text and asks what it means.

Skip for text that goes to another agent or a machine, and for audiences who explicitly want the raw detail.

## Workflow

1. **Classify the input**: *question* (needs an answer), *approval* (needs yes/no to an action), or *statement* (status/finding/result).
2. **Pick the audience** (default: a smart colleague who was away from this task for a day):
   - owner of the work: keep names of things they know, drop plumbing
   - stakeholder / non-technical: zero jargon, impact in their terms
   - unknown: use the colleague default
3. **Extract the point** in one sentence. Question: the decision. Approval: the action and its effect. Statement: what happened and whether it needs anything from them.
4. **Rewrite** with the shape for that class (below).
5. **Run the checklist**. Fix and re-check once; do not loop.
6. **Output only the rewrite** unless the user asked for a comparison. If a fact was missing and you had to leave a gap, say so in one line rather than guessing.

## Shapes

**Question**
```
<The decision, as one plain sentence ending in "?">
Why it matters: <one line, the consequence of each answer>
Options: A) ... B) ...   (2–4, each concrete)
My pick: <option> — <short reason>.  (If it's fine to proceed on this default, say so.)
```

**Approval**
```
I'm about to <plain action on a named thing, e.g. "cancel flight AA123">.
Effect: <what changes, and whether it can be undone>.
OK to go ahead?  [yes / change it / I'll do it myself]
```

**Statement**
```
<Outcome in one sentence — done / blocked / needs you>.
What I found / did: <1–3 short lines>
What I need from you: <exact ask, or "nothing">
```

## Rules

Grounded in plainlanguage.gov, Microsoft's Guidelines for Human-AI Interaction, and agentic-UX approval patterns (sources below).

1. **Main point first.** The first sentence carries the decision or the news. Background comes after, and only if it changes the answer.
2. **Ask only what changes the plan.** If the answer can be inferred from context, state it as an assumption and ask for a veto instead. Cap at 3 questions; one is better.
3. **Always include a recommendation.** Never present options without saying which you'd pick and why (HAX 10, *scope services when in doubt*: disambiguate with a proposed answer). The reader should be able to reply "yes".
4. **Name the real-world action, not the mechanism.** "Delete the 3 old test accounts" not `DELETE /v2/accounts?batch=...`. Drop tool names, IDs, hashes, file paths, and internal phase/state labels unless the reader needs them to find the thing; if so, put them last in a parenthesis.
5. **Say the consequence and reversibility.** One line: what happens on yes, what on no, can it be undone (HAX 16, *convey the consequences of user actions*). Scale detail with risk: low-risk gets one line, money/data-loss/outward-facing gets a full effect statement.
6. **Explain why only on demand or when surprising.** One clause for why you're asking or did something unexpected (HAX 11); offer detail rather than dumping it.
7. **Plain words, active voice, short sentences.** Aim for ~20 words per sentence, none over 40. "use" not "utilise"; "must" not "shall"; positives over double negatives; no and/or; no filler qualifiers.
8. **Define or drop acronyms and coined terms.** First use gets a gloss ("TLS, the encryption that keeps data private") or is replaced. Words the agent invented (phase names, "gate", "lane") are jargon too.
9. **Concrete over vague.** Numbers, names, deadlines: "[who] must [do what] by [when]". "Soon" and "a few" are not answers.
10. **Preserve truth.** Never soften a failure, drop a caveat that affects the decision, or invent a fact to read smoother. Uncertainty stays, in plain words ("I couldn't confirm X").
11. **Keep identifiers the reader will act on** (ticket ID, branch, URL) — once, at the end, not woven through the prose.

## Checklist (before returning)

- [ ] First sentence tells the reader what is wanted or what happened
- [ ] A reader who stops after one sentence knows what to do
- [ ] No tool names, raw IDs, paths, or internal labels in the body
- [ ] Options come with a recommendation; at most 3 questions
- [ ] Consequence and reversibility stated for any action
- [ ] Every acronym/coined term defined or removed
- [ ] No fact added, none that affects the decision removed
- [ ] Shorter than the original (if not, justify: usually the original was already clear — return it unchanged and say so)

## Example

**Before** (agent):
> Phase 6 (IMPL-3) blocked: worktree lpc-fix has uncommitted changes in src/engines/brand.ts and the pre-push hook returned exit 1 (V5 image check). Should I force-push feature/pmt_DSP86-engine-gap-fixes or rebase onto origin/release/ads-dsp-p33 first? Reply 1 or 2.

**After** (human):
> My last change can't be pushed yet: an automatic check on the image build failed.
> Should I fix that first and then push, or push anyway and let the team see the failure?
> Pushing anyway can't be undone for reviewers who pull it in the meantime.
> **My pick:** fix first — it's a small change and keeps the branch clean. Say "go" and I'll do it.
> (Branch: `feature/pmt_DSP86-engine-gap-fixes`)

Note what changed: "force-push vs rebase" was a mechanism choice the reader doesn't need; the real decision is *fix first or push as is*. The recommendation, consequence, and one identifier are kept.

## Sources

- [Plain language quick tips (plainlanguage.gov, archived)](https://webarchive.library.unt.edu/web/20120915094258mp_/http://www.plainlanguage.gov/howto/quickreference/quicktips.cfm): main message first, ~20-word sentences, active voice, cut needless words, test on real readers
- [Guidelines for Human-AI Interaction (Microsoft HAX)](https://www.microsoft.com/en-us/research/blog/guidelines-for-human-ai-interaction-design/): guidelines 4 (contextually relevant info), 10 (scope services when in doubt), 11 (why it did what it did), 16 (consequences of actions)
- [tessl plain-english skill](https://tessl.io/registry/pantheon-ai/plain-english/skills): decision-first structure, audience tiers, "never present options without a recommendation"; written for reports, so this skill adds the question/approval/statement shapes and agent-detail stripping
- [Agentic UX framework](https://www.agentic-ux.com/framework), [AI agent UI patterns (setproduct)](https://www.setproduct.com/blog/ai-agent-ui-design-patterns): ask only what changes the plan, cap at three questions with defaults, concrete action previews, friction scaled to risk
