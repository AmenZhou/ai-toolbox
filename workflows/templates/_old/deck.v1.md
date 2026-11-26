---
name: deck
version: 1
description: Build a slide deck from sources - spec and its approval first, then slides, then agent review, human review and a final agent review until no comments
inputs: topic, sources, output_dir, audience
---

### spec [agent]
do: Read every source in full. Write the deck spec: purpose and audience, key points, storyline (one line per slide), numbers of record with their sources. Follow Step 1 of the sdd-create-deck skill (/Users/haimengzhou/apps/ai-toolbox/skills/sdd-create-deck/SKILL.md; its files are in that folder), but skip its "stop and wait for a yes": spec-approval is that stop. After the yes, set the spec's status to approved as that skill says.
outputs: {output_dir}/{slug}.spec.md
done when: Every key point names the source that proves it, and every number has a source.

### spec-approval [human]
reads: spec
review: Are these the right key points and storyline? Slides are built only after your yes.

### slides [agent]
do: Build the deck from the spec. Follow Steps 2 and 3 of sdd-create-deck (template and check script, both in its ai-toolbox folder).
outputs: {output_dir}/{slug}.html
done when: Every slide in the spec storyline exists, every number on a slide is in the spec, and the check script passes.

### agent-review [agent-review]
reads: spec, slides
review: Can a busy reader who was not in the project follow it? Is any claim stronger than its proof? Does any slide disagree with the spec?
until: no comments
max_rounds: 3

### human-review [human]
reads: spec, slides
review: Comments on the key points, the story, the wording and the look?

### final-review [agent-review]
reads: spec, slides, human-review comments
review: The agent-review questions, plus: is every human-review comment fixed?
until: no comments
max_rounds: 3
