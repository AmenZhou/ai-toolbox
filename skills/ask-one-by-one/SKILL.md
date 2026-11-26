---
name: ask-one-by-one
description: Gather missing requirements or decisions from the user while asking as little as possible. First sorts every open question into critical (only the user can decide it, or a wrong guess is costly or hard to undo) and non-critical (the code, docs, wiki or conversation answer it, or a safe default exists). Resolves the non-critical ones itself, then asks only the critical ones, ONE at a time, each with plain-language context and 2-4 concrete options, one marked "(Recommended)". Use when a task is underspecified and several decisions are open, whenever you are about to ask the user two or more questions, or when the user says "ask me questions one by one", "interview me", "walk me through the choices", "clarify with me step by step", or "/ask-one-by-one". Not for pressure-testing a finished plan (use grilling) and not for rewriting one existing question (use rephrase-for-human).
---

# Ask One by One

The user's attention is the scarce resource. Settle every question you can yourself, and spend
questions only on decisions that are truly theirs or too costly to guess. Ask those one at a time,
each answerable by someone who has not read the code, the logs or the earlier conversation.

## Process

1. **List every open question** privately.
2. **Sort each one: critical or not.** A question is critical only if at least one of these holds:
   - **Only the user can know it**: a preference, a priority, a business or product rule, a name
     or wording they care about, or a fact that no file or tool you can reach contains.
   - **A wrong guess is costly or hard to undo**: deleting or losing data, money, security or
     privacy (which personal data goes where), anything published, sent or pushed to a shared
     place, or a change other people depend on.
   - **The answers lead to very different work** and the evidence does not settle it, so a wrong
     pick means redoing most of the task.

   Everything else is non-critical: the code, docs, wiki, config or this conversation answer it,
   the project already has a convention, there is a conventional default, or it is cheap to change
   later. If you would accept either answer without changing the work, it is not a question.
3. **Resolve the non-critical ones yourself.**
   - Look first: code, docs, wiki, config, git history, earlier conversation. An existing pattern
     in the project beats your own taste.
   - If looking does not settle it, take the conventional default that is easiest to reverse.
   - Note each one for the recap: the decision, your choice, and its source (the file or fact you
     found, or "default").
   - Spend less effort resolving a question than a wrong answer would cost to fix. If you cannot
     resolve it and a wrong guess would cost more than a few minutes to redo, treat it as critical.
4. **Ask the critical ones, one per `AskUserQuestion` call.** Never batch. Put first the questions
   whose answers change the later ones. Ask at most 5. If more are critical, ask the 5 that matter
   most and take the recommended option for the rest, marked "default, not asked" in the recap.
   (This cap overrides the cap of 3 in `rephrase-for-human`.) After each answer, re-check the list:
   drop a question the answer made pointless, add one it opened, and resolve any that stopped being
   critical.
5. **Recap.** Show one table with three columns: decision, choice, source ("you", the file or fact,
   or "default"). Self-resolved decisions go in the same table so the user can overrule any of them.
   - If you asked at least one question, ask once more: proceed, or change something. Then stop asking.
   - If nothing was critical, ask nothing. Show the table, add "Say if any of these should change",
     and carry on with the task.

## Shape of one question

Decision first, then the consequence of each answer, then a recommendation. (`rephrase-for-human`
has the same shape and more wording rules.) Fill the tool fields like this:

- **question**: 2 to 4 plain sentences, standing alone. First sentence is the decision as a
  question. Then one or two sentences of context: what this is about and what each answer
  leads to. Name things the way the user does; no tool names, IDs, file paths or internal
  labels (put one identifier last in parentheses if the user must find the thing).
  Define any term the user did not use first.
- **header**: a 1-2 word chip, 12 characters or fewer.
- **options**: 2 to 4, each a different concrete path, not a rewording. The label is 1 to 5 words.
  The description says what happens if chosen and its main cost, in one sentence.
  Put your pick **first** and end its label with `(Recommended)`; its description says why.
  If the options are genuinely even, still pick one and say so ("no strong difference; chosen for X").
  Do not add an "Other" option; the tool adds it.
- Use the `preview` field only when options are code, config or layouts the user must compare.
- Use `multiSelect: true` only when the options are not mutually exclusive.
- If the user answered with "Other" free text, treat it as the answer; do not re-ask in
  other words. If they say "you decide", take the recommended option and say so in the recap.

## Rules

- One decision per question. If the question contains "and", split it.
- No question whose answer the user already gave in this conversation.
- No question asked to be polite or to cover yourself. A question must be critical (step 2).
- No leading questions: the recommendation is labelled, the other options stay fair.
- Say the consequence when a choice is hard to undo (data loss, money, shared branches).
- Ask in the user's language.
- If `AskUserQuestion` is unavailable (headless run), ask the same question as plain text with
  numbered options, one at a time, and wait for the reply.
- If the user says "enough" or "just decide", jump to the recap using the recommended options.

## Example (shape only; the facts are made up)

Task: "add caching to the report page". Four questions are open.

- Resolved without asking: the cache key format (follows `src/cache/keys.ts`), the expiry
  (5 minutes, what the other cached pages use), and whether to add a test (yes, like the other pages).
- Critical, so asked: where to keep the cache, because the choice changes what must be built and run.

> **question**: "Where should the report page keep its cached results? The page is slow because it
> re-runs a 4-second database query on every visit. A cache stores the result so repeat visits
> are instant, but the data can be a few minutes out of date."
> **header**: `Cache`
> **options**:
> 1. `In server memory (Recommended)`: simplest, no new service. Each server keeps its own copy and it is lost on restart.
> 2. `Redis`: shared by all servers and survives restarts. Needs the Redis service we already run, plus a few more lines of config.
> 3. `No cache, fix the query`: always fresh data, but needs a schema change and is slower to build.
