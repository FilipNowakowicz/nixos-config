---
name: capture-learning-candidate
description: Use when work surfaced a reusable lesson or a missing skill, hook, check or subagent that would have saved real time, to file one compact candidate into the learning inbox without scanning candidate bodies or editing CLAUDE.md, skills, hooks, or invariants directly.
---

# Capture Learning Candidate

When work surfaces something a _future_ agent should know, or a tool it should
have, file one compact candidate into the learning inbox. The weekly
`agent-learning-weekly` run reviews the inbox with a different model and turns
good candidates into checks, hooks, skills or docs (see
`.agents/learning/README.md`). It also mines the week's sessions on its own, so
capturing is optional: do it when you hold evidence the transcript alone would
not show well.

## When to capture (high bar)

File a candidate only when **all** hold:

- The lesson is **reusable** across future sessions, not a one-off fact.
- You have **verifiable evidence** (PR, commit, `file:line`, failing check
  output, or a direct user correction).
- It is **not already** encoded in `CLAUDE.md`, `lib/invariants.nix`, a test, a
  hook, or an existing skill.

Strong triggers: a user correction of how you worked; a validation gate
catching something a careful agent would have avoided; a non-obvious repo
gotcha; or a **tooling wish** (`type: tooling-wish`): a skill, hook, check,
script or subagent that would have saved you turns, reruns or tokens. Put what
its absence cost in `cost`.

Skip one-off context, facts better kept in your own memory, and anything you
cannot back with evidence. Skipping is the default.

## Workflow

1. **Do not scan candidate bodies.** Build 3-6 query terms and run
   `bash .agents/learning/scripts/query-candidates.sh <terms>`. It searches the
   inbox and the archive.
   - A likely duplicate in the inbox: update that file (same `id`) instead.
   - A duplicate in the archive: it was already decided; skip unless you have
     new evidence that the decision was wrong.
2. Write the candidate from `.agents/learning/TEMPLATE.yml` to a scratch file.
   Fill `route`, `best_form` (strongest viable artifact: executable checks over
   hooks, hooks over skills, skills over prose), `evidence`, `observation`,
   `proposed_upgrade`, `date`, `expires` (90 days), `status: open`. Add optional
   fields only when they add routing signal.
3. File it: `bash .agents/learning/scripts/file-candidate.sh <scratch-file>`.
   It validates the candidate and prints its inbox path.
4. Mention the filed path in your work summary.

## Guardrails

- **Never** edit `CLAUDE.md`, skills, hooks, or `lib/invariants.nix` as part of
  capture. Promotion is the reviewer's job.
- Never write candidates into the repo checkout; the inbox is outside git.
- Never put secrets, tokens, or host-specific credentials in a candidate.
- Do not file a candidate to look productive. No evidence, no candidate.
