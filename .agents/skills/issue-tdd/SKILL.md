---
name: issue-tdd
description: Use when converting a rough goal, roadmap item, bug report, or underspecified GitHub issue into an implementation-ready issue with acceptance criteria, non-goals, validation, and user decision questions before code changes.
---

# Issue TDD

Use this before implementation when an issue or goal is not yet precise enough
to build safely. The output is an updated GitHub issue body/comment or a scoped
proposal for the user to approve.

## Goal

Turn a vague goal into a testable issue:

- problem statement
- desired outcome
- acceptance criteria
- non-goals
- likely touched files or modules
- smallest meaningful validation command
- risks and rollback/deploy concerns
- outcome-changing questions for the user

## Workflow

1. Read the source item.
   - Use `gh issue view <number>` for GitHub issues.
   - For roadmap items, read the linked doc section and nearby context.
2. Inspect only enough repo context to scope the work.
   - Use `repo-map-query` before broad exploration when relevant files are not
     obvious.
   - Do not start implementation.
3. Draft the issue in implementation-ready form.
   - Use `issue-driven-development` for acceptance criteria and proving checks.
   - Use `nix-verification-loop` to choose validation when the touched surface is
     Nix, shell, docs, host, package, deploy, or profile-test related.
4. Ask only real decisions before implementation.
   - Ask about security posture, ownership, deploy risk, product behavior,
     document ownership, or PR split boundaries.
   - Do not ask permission to inspect the repo, run normal validation, or proceed
     through routine workflow steps.
5. Update the GitHub issue when asked, or return a paste-ready issue body/comment.

## Decision Gate

If a decision changes the implementation, stop and ask before coding. Use this
shape:

```text
I need one decision before this is implementation-ready:

1. <question>
   Impact: <what changes depending on the answer>
```

Ask at most three questions at once. If there are no blocking decisions, say the
issue is ready for `issue-driven-development`.

## Issue Template

```markdown
## Problem

...

## Desired outcome

...

## Acceptance criteria

- ...

## Non-goals

- ...

## Likely files

- ...

## Validation

- `...`

## Risk / Rollback

- ...

## Decisions

- [ ] ...
```

Run `.agents/scripts/agent-issue-readiness --body-file <path>` (or pipe the
drafted body on stdin) before publishing to confirm it has all the sections
`issue-driven-development` and `scripts/agent-run-issue.sh --require-ready`
expect.

## Handoff

After the issue is scoped and decisions are answered, use
`issue-driven-development` to implement it through validation, PR/CI, merge, and
cleanup when the user wants the full loop. The GitHub issue, issue comments, and
PR body are the durable task state; do not create a separate local ledger unless
the user asks for one.
