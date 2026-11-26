---
name: deck
version: 3
description: Build a slide deck from sources - spec and its approval first, then slides, a plain-language refine pass, then agent review, human review and a final agent review until no comments
inputs: topic, sources, output_dir, audience
mode: auto
---

## Goal
A deck about {topic} for {audience}, at {output_dir}/{slug}.html, built from an owner-approved spec ({output_dir}/{slug}.spec.md) and drawn only from {sources}. It ends with no open review comments and the owner's yes.

## Rules
- Follow the sdd-create-deck skill (/Users/haimengzhou/apps/ai-toolbox/skills/sdd-create-deck/SKILL.md; its template and check script are in that folder).
- Every number on a slide comes from the spec's numbers of record, and each of those has a source. A proposal never reads as a decision.
- Out of scope: publishing, committing or pushing the deck; editing the sources.

## Steps

### spec [agent]
do: Read every source in full. Write the deck spec following Step 1 of sdd-create-deck, but skip its "stop and wait for a yes": spec-approval is that stop.
outputs: {output_dir}/{slug}.spec.md
done when: Every key point names the source that proves it; every number has a source; the sdd-create-deck spec-only check passes.

### spec-approval [human]
reads: spec
review: Are these the right key points and storyline? Slides are built only after your yes.

### slides [agent]
do: Set the spec's status to approved, then build the deck following Steps 2 and 3 of sdd-create-deck.
outputs: {output_dir}/{slug}.html
done when: Every slide in the spec storyline exists; every number on a slide is in the spec; the check script passes and every slide was looked at.

### refine [agent]
do: Follow the rephrase-for-human skill on the words of every slide: lead with the finding, use plain words and short sentences, explain a term at first use, and strip internal detail (tool names, IDs, file paths, jargon). Change wording only, never a number, a date, a decision, a Built / Not built / Proposed / Decided / Open label or an appendix link. Back the deck up first (copy, never overwrite a backup). Give every slide whose editable text changed a new data-edit-key. If a wording rule in the spec changes, update the spec too.
outputs: {output_dir}/{slug}.html
done when: The sdd-create-deck check passes with --before the backup; every number on every slide still matches the spec; every changed slide was looked at on screen; no slide makes a claim it did not make before.

### agent-review [agent-review]
reads: spec, slides
review: Can a busy reader who was not in the project follow it? Is any claim stronger than its proof? Does any slide disagree with the spec?
until: no comments
max_rounds: 3

### human-review [human]
reads: spec, slides
review: Comments on the story, the wording and the look?

### final-review [agent-review]
reads: spec, slides, human-review comments
review: The agent-review questions, plus: is every human-review comment fixed?
until: no comments
max_rounds: 3
