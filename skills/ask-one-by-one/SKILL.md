---
name: ask-one-by-one
description: Gather missing requirements or decisions from the user by asking ONE question at a time, each with plain-language context and 2-4 concrete options, one marked "(Recommended)". Use when a task is underspecified and several decisions are needed, or when the user says "ask me questions one by one", "interview me", "walk me through the choices", "clarify with me step by step", or "/ask-one-by-one". Not for pressure-testing a finished plan (use grilling) and not for rewriting one existing question (use rephrase-for-human).
---

# Ask One by One

Collect decisions through a short sequence of single questions. Each question must be answerable
by someone who has not read the code, the logs or the earlier conversation.

## Process

1. **Look before you ask.** Read the code, docs, wiki or config first. Anything you can find out
   yourself is not a question; state it as an assumption in the recap instead.
2. **List the open decisions** privately and order them so that answers which change later
   questions come first. Drop any decision that is cheap to change later: take the default and list it in the recap.
   Ask at most 5 questions (one is fine). If more are open, ask the 5 that matter most and
   default the rest. This cap overrides the cap of 3 in `rephrase-for-human`.
3. **Ask one question per `AskUserQuestion` call.** Never batch. After each answer, re-check the
   list: a question the answer made pointless is dropped, a new one it opened is added.
4. **Write each question for a reader who lost the context** (shape below).
5. **Recap and confirm.** After the last answer, show a table of "decision, choice" plus the
   assumptions you made, and ask once: proceed, or change something. Then stop asking.

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
- No leading questions: the recommendation is labelled, the other options stay fair.
- Say the consequence when a choice is hard to undo (data loss, money, shared branches).
- Ask in the user's language.
- If `AskUserQuestion` is unavailable (headless run), ask the same question as plain text with
  numbered options, one at a time, and wait for the reply.
- If the user says "enough" or "just decide", jump to the recap using the recommended options.

## Example (shape only; the facts are made up)

Task: "add caching to the report page", cache backend unknown.

> **question**: "Where should the report page keep its cached results? The page is slow because it
> re-runs a 4-second database query on every visit. A cache stores the result so repeat visits
> are instant, but the data can be a few minutes out of date."
> **header**: `Cache`
> **options**:
> 1. `In server memory (Recommended)`: simplest, no new service. Each server keeps its own copy and it is lost on restart.
> 2. `Redis`: shared by all servers and survives restarts. Needs the Redis service we already run, plus a few more lines of config.
> 3. `No cache, fix the query`: always fresh data, but needs a schema change and is slower to build.
