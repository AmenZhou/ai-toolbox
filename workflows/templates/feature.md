---
name: feature
version: 3
description: Build a feature of a project with specs first - new worktree branch, specs updated with the sdd skill, an agent review of the specs, a spend gate, implementation, two rounds of code review and fixes, a fresh verification, then commit and push the branch
inputs: repo, feature, spec_dir, test_command, base_branch, push
mode: gated
---

<!-- Defaults: worktree = /Users/haimengzhou/apps/<repo folder name>-{slug}; branch = feature/{slug} from {base_branch}.
     base_branch = origin/main. push = yes. spec_dir = the project's spec folder (README.md with a "| Status | Meaning |" table); if the project has none, the spec step uses spec-driven-development instead; "none" skips the specs and the spec review.
     Written 2026-11-26 from the owner's prompt: worktree, sdd specs, spec review, implementation, smart-code-review + fixes twice.
     v2 (2026-11-26, owner): commit and push the branch at the end; mode gated because the last step pushes.
     v3 (2026-11-26, owner, from a review of past task plans): base_branch input; spec review limited to what this task changes and ends at no [must]; spend-gate step; optional specs and push; fresh verify step before push. -->

## Goal
{feature} is built in {repo} on its own branch, feature/{slug}, in a new worktree made from {base_branch}, and the branch is pushed to origin if {push} is yes. The specs in {spec_dir} describe it first (unless it is "none"). The code passes {test_command}, two rounds of code review and a fresh verification, with every finding fixed or declined with a reason.

## Rules
- Work only in the new worktree; never edit the main checkout of {repo}.
- Commit only on feature/{slug}. Push only feature/{slug}, only in the last step, and only if {push} is yes. Never merge, push main, open a merge request or post review comments: the owner does that.
- If {spec_dir} is "none", specs and spec-review are skipped and recorded as "no specs", and the plan marks those phases skipped.
- No paid model call, no live service and no shared resource (a running stack, a shared port or image name) is used without the owner's yes in spend-gate. Record the state before and restore it after.
- A spec status follows its evidence: a new requirement is Proposed, or Decided with the owner's date; it becomes Building when code lands on the branch, and Built only after a merge to main.
- Ask before deleting, moving or overwriting a file. No compound shell commands. Scratch files go under /Users/haimengzhou/apps/ai-console/tmp/.

## Steps

### worktree [agent]
executor: inline
do: Follow the checkout-worktree skill: create the worktree /Users/haimengzhou/apps/<repo folder name>-{slug} on a new branch feature/{slug} from {base_branch} of {repo}, and register it in workspace.local.md. Stop if the folder or the branch already exists. Run {test_command} once as the baseline and record the result.
outputs: /Users/haimengzhou/apps/<repo folder name>-{slug}
done when: The worktree exists on feature/{slug}, it is registered, and the baseline test result is recorded (pass count, or the failures that exist before any change).

### specs [agent]
do: If {spec_dir} is "none", record "no specs" and finish this step. Otherwise, if {spec_dir} has a README.md with a status table, follow the sdd-update-specs skill with {feature} as an owner decision: add the new requirements (next free ids, status Proposed or Decided with the date) and update the README, the roadmap and every file the feature touches; it asks the owner once before editing. Otherwise follow spec-driven-development to write a new spec for {feature}. Each requirement must be testable.
outputs: {spec_dir}
done when: Every part of {feature} maps to at least one requirement id with a status, the skill's check script passes (sdd-update-specs) or the spec has acceptance criteria per requirement (spec-driven-development), and the owner's yes is recorded.

### spec-review [agent-review]
reads: specs
review: Check only the requirements this task adds or changes, and what they touch; do not ask for changes to requirements this task leaves alone. Can an engineer build {feature} from these specs without guessing? Is any requirement untestable, contradictory, missing a status, or stronger than its evidence? Does any part of {feature} have no requirement?
max_rounds: 3

### spend-gate [human]
reads: specs
review: Does building or testing {feature} need a paid model call, a live service, or a shared resource such as a running stack, a shared port or an image name? If yes: what is used, for how long, what is the cost ceiling, and what restores the state afterwards? Reply "not needed" if none. A "go" is not a yes.

### implement [agent]
do: In the worktree, build {feature} to the reviewed specs (or to the owner's description if there are no specs). Use a paid call, a live service or a shared resource only as spend-gate allowed. Write a test for each new requirement id, keep the code to the project's conventions, run {test_command}, and commit on feature/{slug} with messages that name the requirement ids.
outputs: commits on feature/{slug}
done when: {test_command} passes with no new failure against the baseline, every new requirement id is covered by code and a test (or listed as not done, with the reason), and the worktree is clean.

### code-review-1 [agent]
executor: inline
do: Run the smart-code-review skill on feature/{slug} against {base_branch}. When it asks where to put the findings, choose the local review document: never post to a merge request. Save it as the outputs file.
outputs: /Users/haimengzhou/apps/ai-console/tmp/{slug}/code-review-1.md
done when: The review document exists and lists every finding with its severity and file:line, or says there are none.

### fix-1 [agent]
do: Follow the address-code-review skill on the code-review-1 document: judge each finding (valid, already done, out of scope, will not fix), fix the valid ones in the worktree, run {test_command}, and commit on feature/{slug}. Write the outcome of each finding back into the document.
outputs: /Users/haimengzhou/apps/ai-console/tmp/{slug}/code-review-1.md
done when: Every finding is marked fixed or declined with a reason, {test_command} passes, and the worktree is clean.

### code-review-2 [agent]
executor: inline
do: Run the smart-code-review skill again on feature/{slug} against {base_branch}, as in code-review-1, with a fresh review that does not read code-review-1.md.
outputs: /Users/haimengzhou/apps/ai-console/tmp/{slug}/code-review-2.md
done when: The review document exists and lists every finding, or says there are none.

### fix-2 [agent]
do: As fix-1, on the code-review-2 document. Then, if any requirement's status changed (code now on the branch), follow sdd-update-specs to set it to Building, citing the commits.
outputs: /Users/haimengzhou/apps/ai-console/tmp/{slug}/code-review-2.md
done when: Every finding is marked fixed or declined with a reason, {test_command} passes, the worktree is clean, and the specs show Building for what was built.

### verify [agent-review]
reads: implement, specs
review: Run {test_command} yourself on feature/{slug}. For each requirement this task added or changed (or each part of {feature} if there are no specs): is there code and a test that would fail without it? Did any file outside what {feature} needs change? Is anything left running, uncommitted or pushed that should not be?
until: no comments
max_rounds: 3

### push [agent]
executor: inline
do: Act only if {push} is yes; otherwise record "not pushed: push is no" and finish. In the worktree, check that git status is clean apart from files this task made, and stage only those by name (never other untracked files or secrets). Commit what is left with the session's attribution lines, run {test_command} once more, then push feature/{slug} to origin with upstream tracking. Do not push main, merge, or open a merge request. If the push is refused, stop and report the reason; never force-push.
outputs: feature/{slug} on origin
done when: {push} is no, or origin/feature/{slug} points at the local HEAD (git status says "up to date"), {test_command} passed on that commit, and the commit list since {base_branch} is recorded.
