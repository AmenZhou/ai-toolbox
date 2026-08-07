---
name: typescript-best-practices
description: This skill should be used whenever writing, editing, or reviewing TypeScript (.ts/.tsx) code, or when the user asks to "write TypeScript", "add a TS file", "convert to TypeScript", or similar. Applies general-purpose TypeScript best practices — strict typing, naming, error handling, tooling, and testing conventions — across any TypeScript project. Defer to a project's own documented conventions (e.g. a repo's CLAUDE.md or internal style doc) where they conflict; this skill fills gaps, it doesn't override local convention.
version: 1.0.0
---

# TypeScript Best Practices

Guardrails for writing idiomatic, type-safe TypeScript. Apply these by default; a project's own documented conventions (CLAUDE.md, ESLint config, existing code patterns in the file you're editing) take precedence when they conflict.

## Compiler configuration

- Enable `strict: true` in `tsconfig.json` (bundles `strictNullChecks`, `noImplicitAny`, `strictFunctionTypes`, etc.) — the single highest-leverage setting for catching real bugs.
- Also prefer `noUncheckedIndexedAccess` (array/object index access returns `T | undefined`) and `exactOptionalPropertyTypes` for new projects.
- Never weaken strictness to silence an error — fix the type, don't loosen the config.

## Type safety

- Never use `any`. When a type is genuinely unknown until runtime-checked, use `unknown` and narrow it before use (type guards, `zod`/schema validation, discriminated unions).
- Avoid type assertions (`as T`) and non-null assertions (`!`) — they suppress the compiler without adding a runtime check, so they fail silently at the exact place you claimed safety. Prefer narrowing (`if (x != null)`, `Array.isArray`, custom type guards `x is T`).
- Never use `@ts-ignore` / `@ts-expect-error` / `@ts-nocheck` to paper over an error — the underlying type mismatch is almost always a real bug or a missing narrowing step.
- Model state with discriminated unions (`{ status: "ok"; data: T } | { status: "error"; error: E }`) instead of optional fields that can be in invalid combinations.
- Let the compiler infer trivially-inferred types (`const x = 5`); add explicit annotations only where they aid readability or the inference would be too wide (e.g. function parameters, exported function return types).
- Prefer optional fields (`field?: T`) over `field: T | undefined` in object/interface shapes — `?` also permits omitting the key entirely, which is usually the intent.

## Null / undefined handling

- Use `===`/`!==` always; the sole exception is `== null` to test for both `null` and `undefined` in one check.
- Don't let `null` and `undefined` both leak through your own APIs for the same meaning — pick one (prefer `undefined`, matching optional-field convention) and document it.

## Naming & structure

- `camelCase` for variables/functions, `PascalCase` for types/interfaces/classes/enums, `UPPER_SNAKE_CASE` for true constants.
- Don't encode the type in the name (no `nameString`, no Hungarian notation) — TypeScript already carries that information.
- No leading/trailing underscores for "private" members — use the `private`/`#` access modifiers instead.
- One concern per module; keep exported surface area small — export types/functions that are actually consumed elsewhere, keep helpers unexported.
- Prefer `readonly` on interface/type properties and array types (`readonly T[]` / `ReadonlyArray<T>`) for data that shouldn't be mutated after construction.

## Functions & async

- Give exported/public functions explicit parameter and return types — don't rely on inference across a module boundary.
- Prefer `async`/`await` over raw `.then()` chains; always handle rejection (`try/catch` or a `.catch`) — an unhandled promise rejection is a silent failure.
- Avoid `Promise<any>` — type what the promise actually resolves to, use `Promise<void>` for fire-and-forget.
- Don't use `with` or `eval`/`Function(string)` — both are unsafe and break strict-CSP environments.

## Tooling

- Lint with `typescript-eslint`: start from `recommended-type-checked` + `stylistic-type-checked` (enables type-aware rules like `no-floating-promises`, `no-unsafe-assignment`); move to `strict-type-checked` only once the team is fluent in TS, since it trades ergonomics for maximum strictness.
- Format with Prettier (or Biome for a single-tool lint+format setup) — don't hand-format or bikeshed style in review; let the tool decide.
- Wire both into CI so type errors and lint failures block merge, not just local dev.

## Testing

- Co-locate or mirror test files (`foo.ts` → `foo.test.ts`); one behavior per test.
- Name tests by behavior, not implementation (`"returns 429 after the rate limit is exceeded"`, not `"test rate limiter"`).
- Type test fixtures and mocks — an untyped `any` mock silently drifts from the real interface it stands in for.

## Documentation

- Use TSDoc (`/** ... */` with `@param`/`@returns`) on exported/public functions and types where the *why* or a non-obvious contract needs stating — not on self-evident code.
- Follow the repo's own no-comments-by-default convention if one exists; TSDoc on public API surfaces is the exception, not a blanket requirement.

## Project-specific layering

Some repos define stricter or additional conventions on top of these general rules (error-code formats, DI patterns, DB access helpers, etc.) — always check for a project `CLAUDE.md` or internal style doc first and follow it where it's more specific than this skill. This skill is the default floor, not a ceiling.

## References

- [TypeScript style guide (ts.dev)](https://ts.dev/style/)
- [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html)
- [typescript-eslint — shared configs](https://typescript-eslint.io/users/configs/)
- [Microsoft TypeScript Wiki — Coding guidelines](https://github.com/microsoft/TypeScript/wiki/Coding-guidelines)
