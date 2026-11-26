---
name: feature
version: 2
description: Build a feature of a project with specs first - new worktree branch, specs updated with the sdd skill, an agent review of the specs, implementation, two rounds of code review and fixes, then commit and push the branch
inputs: repo, feature, spec_dir, test_command
mode: gated
---

<!-- Defaults: worktree = /Users/haimengzhou/apps/<repo folder name>-{slug}; branch = feature/{slug} from origin/main.
     spec_dir = the project's spec folder (README.md with a "| Status | Meaning |" table); if the project has none, the spec step uses spec-driven-development instead.
     Written 2026-11-26 from the owner's prompt: worktree, sdd specs, spec review, implementation, smart-code-review + fixes twice.
     v2 (2026-11-26, owner): commit and push the branch at the end; mode gated because the last step pushes. -->

## Goal
{feature} is built in {repo} on its own branch, feature/{slug}, in a new worktree, and the branch is pushed to origin. The specs in {spec_dir} describe it first. The code passes {test_command} and two rounds of code review, with every finding fixed or declined with a reason.

## Rules
- Work only in the new worktree; never edit the main checkout of {repo}.
- Commit only on feature/{slug}. Push only feature/{slug}, and only in the last step. Never merge, push main, open a merge request or post review comments: the owner does that.
- A spec status follows its evidence: a new requirement is Proposed, or Decided with the owner's date; it becomes Building when code lands on the branch, and Built only after a merge to main.
- Ask before deleting, moving or overwriting a file. No compound shell commands. Scratch files go under /Users/haimengzhou/apps/ai-console/tmp/.

## Steps

### worktree [agent]
executor: inline
do: Follow the checkout-worktree skill: create the worktree /Users/haimengzhou/apps/<repo folder name>-{slug} on a new branch feature/{slug} from origin/main of {repo}, and register it in workspace.local.md. Stop if the folder or the branch already exists. Run {test_command} once as the baseline and record the result.
outputs: /Users/haimengzhou/apps/<repo folder name>-{slug}
done when: The worktree exists on feature/{slug}, it is registered, and the baseline test result is recorded (pass count, or the failures that exist before any change).

### specs [agent]
do: If {spec_dir} has a README.md with a status table, follow the sdd-update-specs skill with {feature} as an owner decision: add the new requirements (next free ids, status Proposed or Decided with the date) and update the README, the roadmap and every file the feature touches; it asks the owner once before editing. Otherwise follow spec-driven-development to write a new spec for {feature}. Each requirement must be testable.
outputs: {spec_dir}
done when: Every part of {feature} maps to at least one requirement id with a status, the skill's check script passes (sdd-update-specs) or the spec has acceptance criteria per requirement (spec-driven-development), and the owner's yes is recorded.

### spec-review [agent-review]
reads: specs
review: Can an engineer build {feature} from these specs without guessing? Is any requirement untestable, contradictory, missing a status, or stronger than its evidence? Does any part of {feature} have no requirement?
until: no comments
max_rounds: 3

### implement [agent]
do: In the worktree, build {feature} to the reviewed specs. Write a test for each new requirement id, keep the code to the project's conventions, run {test_command}, and commit on feature/{slug} with messages that name the requirement ids.
outputs: commits on feature/{slug}
done when: {test_command} passes with no new failure against the baseline, every new requirement id is covered by code and a test (or listed as not done, with the reason), and the worktree is clean.

### code-review-1 [agent]
executor: inline
do: Run the smart-code-review skill on feature/{slug} against main. When it asks where to put the findings, choose the local review document: never post to a merge request. Save it as the outputs file.
outputs: /Users/haimengzhou/apps/ai-console/tmp/{slug}/code-review-1.md
done when: The review document exists and lists every finding with its severity and file:line, or says there are none.

### fix-1 [agent]
do: Follow the address-code-review skill on the code-review-1 document: judge each finding (valid, already done, out of scope, will not fix), fix the valid ones in the worktree, run {test_command}, and commit on feature/{slug}. Write the outcome of each finding back into the document.
outputs: /Users/haimengzhou/apps/ai-console/tmp/{slug}/code-review-1.md
done when: Every finding is marked fixed or declined with a reason, {test_command} passes, and the worktree is clean.

### code-review-2 [agent]
executor: inline
do: Run the smart-code-review skill again on feature/{slug} against main, as in code-review-1, with a fresh review that does not read code-review-1.md.
outputs: /Users/haimengzhou/apps/ai-console/tmp/{slug}/code-review-2.md
done when: The review document exists and lists every finding, or says there are none.

### fix-2 [agent]
do: As fix-1, on the code-review-2 document. Then, if any requirement's status changed (code now on the branch), follow sdd-update-specs to set it to Building, citing the commits.
outputs: /Users/haimengzhou/apps/ai-console/tmp/{slug}/code-review-2.md
done when: Every finding is marked fixed or declined with a reason, {test_command} passes, the worktree is clean, and the specs show Building for what was built.

### push [agent]
executor: inline
do: In the worktree, check that git status is clean apart from files this task made, and stage only those by name (never other untracked files or secrets). Commit what is left with the session's attribution lines, run {test_command} once more, then push feature/{slug} to origin with upstream tracking. Do not push main, merge, or open a merge request. If the push is refused, stop and report the reason; never force-push.
outputs: feature/{slug} on origin
done when: origin/feature/{slug} points at the local HEAD (git status says "up to date"), {test_command} passed on that commit, and the commit list since main is recorded.
