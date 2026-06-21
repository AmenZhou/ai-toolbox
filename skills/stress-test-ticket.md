---
name: stress-test-ticket
description: Workflow for handling a stress test ticket. Use when the user asks to "run a ticket", "work on a ticket", or mentions a ticket ID (e.g., k6-4, mon-3) for the stress-test project.
---

# Stress Test Ticket Workflow

This skill automates the end-to-end lifecycle of a stress test ticket using `task-orchestrate`.

## Instructions

When triggered with a ticket ID (e.g., `<ticket_id>`), invoke `task-orchestrate` with the following prompt:

```
/task-orchestrate
  worktree checkout new folder and branch for the <ticket_id>
  ticket in the stress-test project
  design and implement
  add tests and pass tests
  code review and address comments
  push
```

### Parameters

- `<ticket_id>`: The dynamic ticket identifier provided by the user (e.g., `mon-3`, `k6-5`).

### Context

- **Source Repo:** `/Users/haimengzhou/apps/dsp_stress_test`
- **Base Directory:** `/Users/haimengzhou/apps/`
