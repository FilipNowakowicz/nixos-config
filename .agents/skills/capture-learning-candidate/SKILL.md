---
name: capture-learning-candidate
description: Use at the end of non-trivial work to record a reusable lesson as a reviewed learning candidate, without editing CLAUDE.md, skills, hooks, or invariants directly.
---

# Capture Learning Candidate

When work surfaces something a *future* agent should know, record it as a
candidate under `.agents/learning/candidates/`. Candidates are proposals,
reviewed and promoted later by a human-gated reviewer — see
`.agents/learning/README.md`. Capturing a candidate must never change agent
behavior on its own.

## When to capture (high bar)

File a candidate only when **all** hold:

- The lesson is **reusable** across future sessions, not a one-off fact.
- You have **verifiable evidence** (commit, `file:line`, failing check output,
  or a direct user correction).
- It is **not already** encoded in `CLAUDE.md`, `lib/invariants.nix`, a test, a
  hook, or an existing skill.

Strong triggers: a user correction of how you worked; a validation gate
(`scripts/validate.sh`, `merge-gate`) catching something a careful agent would
have avoided; a non-obvious repo gotcha you only learned by hitting it.

## When NOT to capture

- One-off or session-only context (belongs in your normal summary, nowhere else).
- Anything already covered by docs, invariants, tests, hooks, or skills.
- Ephemeral user/preference facts better suited to auto-memory.
- A lesson you cannot back with evidence.

Prefer **fewer, higher-signal** candidates. Skipping is the default.

## Workflow

1. **Check for duplicates first.** Scan `.agents/learning/candidates/` and the
   relevant `CLAUDE.md` / `lib/invariants.nix`. If a candidate already covers
   it, **update that file in place** — do not append a near-duplicate.
2. Copy `.agents/learning/TEMPLATE.md` to
   `.agents/learning/candidates/<date>-<kebab-slug>.md`.
3. Fill every field. Set `expires` to `date + 30d` and `status: open`.
4. For **Best form**, pick the strongest viable destination from the promotion
   hierarchy (assertion/test > hook > skill > prose). If you propose anything
   weaker than an executable check, justify why a stronger form is impossible. A
   lesson that *could* be executable may not propose prose.
5. Mention the captured candidate's path in your work summary.

## Guardrails

- **Never** edit `CLAUDE.md`, skills, hooks, or `lib/invariants.nix` as part of
  capture. Promotion is a separate, reviewed step.
- Never put secrets, tokens, or host-specific credentials in a candidate.
- Do not file a candidate to look productive. No evidence, no candidate.
