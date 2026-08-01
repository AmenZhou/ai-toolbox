---
name: blocked-report
description: Fast read-only report of gated (awaiting_go), needs_human, and failed
  task-orchestrate rows — no SKILL.md-scale planning, no per-file LLM reads. Use for
  "show blocked tasks", "what's gated", "list needs_human tasks", "/orch tend gated/blocked/
  needs human tasks".
inline: true
---

# /blocked-report

Run:
```bash
bash /Users/haimengzhou/apps/ai-console/.orchestrate/bin/report-blocked.sh \
  /Users/haimengzhou/apps/ai-console
```

Print stdout verbatim to the user. Do not read `project.md`, `SKILL.md`, or any task file
directly — the script already did the O(1) pass. Do not offer to resolve/unblock anything here;
point to `/unblock-task` for that.
