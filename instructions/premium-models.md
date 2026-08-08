## Premium Models for Investigation & Planning

Investigation, planning, and research phases must use Claude Sonnet 5 (or Opus 5 if available). Fallback to session default if unavailable.

These phases are high-cognition work where premium model reasoning significantly improves quality of output (better decomposition, more accurate dependencies, superior analysis). Cost justifies the upgrade compared to the impact of poor planning on downstream work.

### Phase Keywords Triggering Premium Model (Sonnet)

The following keywords in phase names or task instructions indicate premium model usage:
- `investigate` / `investigation` / `INV` — explicit investigation phases
- `plan` / `planning` / `PLAN` — planning and decomposition phases
- `research` / `research phase` — research and discovery work
- `derive` / `derivation` — deriving requirements, dependencies, or design
- `discovery` — exploration and exploratory analysis

Tickets tagged `source:investigation` or ending with `-INV` suffix always use premium models.

### Three Skills Using Premium Models

The following skills systematically use premium models for investigation/planning phases:
- **grounded-investigate** — Wiki-first dual-method investigation; Sonnet used in Steps 2–4 (both methods + cross-validation)
- **task-orchestrate** — Phase 1 (Planning/Complexity Analysis) uses Sonnet; any phase explicitly marked `investigate` or `research` uses Sonnet
- **task-breakdown** (formerly breakdown-to-inbox) — Steps 1–2 (Understanding + Decomposition) use Sonnet for accurate dependency derivation

### Implementation by Tool

**Claude Code (Agent tool):**
```javascript
// Investigation phase — request Sonnet; will degrade gracefully if unavailable
Agent({
  description: "Investigate X using dual-method validation",
  prompt: "...investigation prompt...",
  model: "sonnet",  // Sonnet requested; falls back to haiku if unavailable
  run_in_background: false
})
```

The `model` parameter takes precedence over agent definition defaults and parent session model. Subagents run at the specified tier independently. Retry escalation: Sonnet (retry 1) → Opus (retry 2, if available) → escalate to needs_human (retry 3+).

**Cursor:**
Before investigation/planning phases, switch Cursor to Sonnet in Settings (⌘ + Shift + J → "Sonnet 5"). Cursor does not support per-call model selection, so tier choice is IDE-level. Switch back to Haiku after completion for cost efficiency. Skill instructions will signal when this is required.

### Model Selection Hierarchy

For investigation/planning phases:
1. **Sonnet 5** (preferred)
2. **Sonnet 4** (if Sonnet 5 unavailable)
3. **Haiku** (fallback; degraded but functional)
4. **Opus 5** (optional upgrade for particularly complex multi-step investigations)

On retry, escalate: Haiku → Sonnet → Opus (if available).

### Rationale

Premium models cost more, but investigation quality justifies the investment. Poor planning with budget-tier models cascades into implementation rework, testing delays, and misaligned dependencies. High-quality investigation using Sonnet prevents costly downstream mistakes. Routine implementation and verification phases use standard-tier (Haiku) for cost efficiency.

All phase keywords, skill guidance, and Agent() examples are documented in respective SKILL.md files (ai-toolbox/skills/) with frontmatter fields `investigation_model_tier: sonnet` and `planning_model_tier: sonnet`.
