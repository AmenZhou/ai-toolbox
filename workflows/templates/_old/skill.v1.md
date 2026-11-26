---
name: skill
version: 1
description: Create a new skill from a brief - draft, test with fresh agents, an agent review, your approval, a final review of at least two rounds, then install and publish
inputs: skill_name, brief, reference, output_dir, max_lines
---

<!-- Defaults: output_dir = /Users/haimengzhou/apps/ai-console/tmp/{skill_name}/ ; max_lines = 150.
     Built from the sdd-update-specs and sdd-create-deck sessions of 2026-11-24 to 2026-11-26.
     min_rounds is an addition to the task-workflow format: the runner must honor it as written in the step. -->

### brief [agent]
do: Read the brief and the reference material in full. Check that {skill_name} clashes with no installed skill (look in /Users/haimengzhou/.claude/skills/ and /Users/haimengzhou/apps/ai-toolbox/skills/). Ask only what the sources cannot answer: at most 5 questions, one at a time, each with a recommendation (the ask-one-by-one skill). Write the brief: purpose, trigger phrases, "do not use for" cases, inputs, steps, safety rules, the tests (see tests), and the line limit.
outputs: {output_dir}/{slug}.brief.md
done when: Every item of the brief is filled in and the name clashes with no installed skill.

### draft [agent]
do: Follow the skill-creator skill. Write SKILL.md in /Users/haimengzhou/apps/ai-toolbox/skills/{skill_name}/ with a pushy description (trigger phrases and a "Do NOT use for" list), numbered steps that name the files they use, a safety section, and the reason behind each rule. Add scripts/ and assets/ only where a check or a template is needed. Give any check script a --selftest. Scratch files go under /Users/haimengzhou/apps/ai-console/tmp/, never the system temp folder. Do not install or sync anything in this step.
outputs: /Users/haimengzhou/apps/ai-toolbox/skills/{skill_name}/SKILL.md
done when: SKILL.md is under {max_lines} lines, every file it names exists, and the self-test of any check script passes.

### tests [agent]
do: Run four tests with fresh agents, each on copies of the material in {output_dir}. (1) The self-test, and one run of the skill on real reference material: report findings, never edit the reference. (2) A made-up topic, end to end, stopping at each approval gate. (3) A request the skill must refuse. (4) An input with no source, which must be left out and listed. Fix every gap found in SKILL.md and rerun the test that exposed it.
outputs: {output_dir}/{slug}.tests.md
done when: Each test is recorded as pass or fail, and every gap is fixed or listed.

### agent-review [agent-review]
reads: draft, tests
review: Can an agent follow SKILL.md without guessing? Is there a rule with no exemption, a term that is not defined, a contradiction between two steps, or a file the skill names that does not exist?
until: no comments
max_rounds: 3

### human-review [human]
reads: draft, tests
review: Comments on the steps, the wording and the limits? Is it OK to install the skill into /Users/haimengzhou/.claude/skills/? Add a pointer line to the project CLAUDE.md? Commit and push to ai-toolbox on a branch, and merge to main?

### final-review [agent-review]
reads: draft, human-review comments
review: The agent-review questions, plus: is every human-review comment fixed? Run at least 2 rounds, each with a new fresh agent, even if round 1 returns no comments.
min_rounds: 2
until: no comments
max_rounds: 4

### install [agent]
do: Act only if human-review said yes to installing. Copy the folder with a plain cp -R to /Users/haimengzhou/.claude/skills/{skill_name}, leaving out __pycache__ and old SKILL-v*.md files. Do not run the full ai-toolbox sync.sh: it copies only SKILL.md and rewrites global files. If the target folder already exists, set the step to stopped and ask before overwriting. Run the self-test from the installed copy. Add the CLAUDE.md pointer line only if human-review said yes, and back CLAUDE.md up first.
outputs: /Users/haimengzhou/.claude/skills/{skill_name}/SKILL.md
done when: The self-test passes from the installed copy, or human-review said not to install.

### publish [agent]
do: Act only if human-review said yes to committing and pushing. In /Users/haimengzhou/apps/ai-toolbox create the branch feat/{skill_name} from main; never commit on main. Stage only the skill's real files by name (not __pycache__, old SKILL-v*.md files or other untracked files). Commit with the attribution lines of the session, then push the branch to origin. Merge into main and push main only if human-review said so. No compound shell commands.
outputs: branch feat/{skill_name} on origin
done when: The branch is pushed (and main too, if approved), or human-review said not to publish.
