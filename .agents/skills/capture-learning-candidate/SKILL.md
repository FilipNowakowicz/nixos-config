---
name: capture-learning-candidate
description: Use at the end of high-signal work to record one compact reviewed learning candidate, without scanning candidate bodies or editing CLAUDE.md, skills, hooks, or invariants directly.
---

# Capture Learning Candidate

When work surfaces something a _future_ agent should know, record one compact
candidate under `.agents/learning/candidates/`. Candidates are machine-routed
proposals reviewed later by a human-gated reviewer — see
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
have avoided; a non-obvious repo gotcha you only learned by hitting it; or a
repo/CI fix that should become a durable check, hook, skill, or doc update.

## When NOT to capture

- One-off or session-only context (belongs in your normal summary, nowhere else).
- Anything already covered by docs, invariants, tests, hooks, or skills.
- Ephemeral user/preference facts better suited to auto-memory.
- A lesson you cannot back with evidence.

Prefer **fewer, higher-signal** candidates. Skipping is the default.

## Workflow

1. **Do not scan candidate bodies.** Build 3-6 query terms from the issue
   shape, file paths, commands, CI job, host, or hook involved.
2. Run `bash .agents/learning/scripts/query-candidates.sh <terms>`.
   - If it returns a likely duplicate, open only that candidate file and update
     it in place.
   - If it returns nothing relevant, create a new candidate.
3. Copy `.agents/learning/TEMPLATE.yml` to
   `.agents/learning/candidates/<date>-<kebab-slug>.yml`.
4. Fill the required fields with terse, grep-friendly values:
   - `route`: `implement-fix`, `promote-memory`, `promote-skill`,
     `promote-hook`, `promote-doc`, or `reject`.
   - `best_form`: strongest viable artifact, preferring executable checks over
     hooks, hooks over skills, and skills over prose docs.
   - `evidence`, `observation`, `proposed_upgrade`, plus `date`/`expires`/
     `status`.
     The optional fields (`triggers`, `targets`, `dedupe_key`, `type`, `risk`,
     `agent`) are commented out in the template — add one only when it adds real
     routing signal. Do not pad fields to look thorough.
5. Mention the captured candidate's path in your work summary.

## Guardrails

- **Never** edit `CLAUDE.md`, skills, hooks, or `lib/invariants.nix` as part of
  capture. Promotion is a separate, reviewed step.
- Never read all candidates to dedupe. The index/query helper is the routing
  surface for normal capture.
- Never put secrets, tokens, or host-specific credentials in a candidate.
- Do not file a candidate to look productive. No evidence, no candidate.
