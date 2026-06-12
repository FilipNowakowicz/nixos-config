---
name: issue-driven-development
description: Use when taking a scoped GitHub issue, review finding, roadmap item, or bug report through implementation, validation, PR/CI, merge, cleanup, and optional learning capture.
---

# Issue-Driven Development

Use this workflow for non-trivial implementation work, especially when the task
starts from a scoped issue, review finding, CI failure, roadmap item, or bug.
If the source item is still vague, use `issue-tdd` first.

## Workflow

1. Establish the source item:
   - GitHub issue/PR review comment, local review note, roadmap entry, CI failure,
     or user-stated bug.
   - For a GitHub issue, especially before dispatching a batch via
     `scripts/agent-run-issue.sh`, run
     `.agents/scripts/agent-issue-readiness --issue <n>` to check it has the
     sections an implementation agent needs (problem/desired outcome or
     summary, acceptance criteria, non-goals, validation, risk/rollback). If it
     reports missing sections, use `issue-tdd` to fill them in before editing.
2. Confirm or restate the acceptance criteria in concrete terms:
   - What behavior changes?
   - What must not change?
   - What command/check will prove completion?
   - What decisions are already answered or explicitly out of scope?
3. Ask only outcome-changing questions before editing:
   - Ask about security posture, ownership, deploy risk, document ownership,
     product behavior, or PR split boundaries.
   - Do not ask permission to inspect, validate, or proceed through routine
     workflow steps.
4. Create or identify the failing check before editing when feasible:
   - Nix invariant, fixture, package check, profile test, smoke test, doc-link check,
     or a narrow command from `scripts/validate.sh`.
5. Create a targeted branch/worktree when useful for isolation.
   - Prefer `codex/<short-scope>` or the established branch prefix.
   - Keep one issue to one PR unless the scope clearly splits.
6. Implement the smallest durable repo-side fix.
7. Run the acceptance check, then any broader validation justified by the touched surface.
8. Open or update the PR when the user wants the full loop.
   - Link the source issue.
   - Include validation evidence.
   - For Markdown-rich issue or PR bodies, prefer `gh ... --body-file -`
     with a single-quoted heredoc, or an equivalently quoted body file. Do not
     pass Markdown containing backticks through a double-quoted `--body`
     argument; the shell can evaluate those backticks before `gh` receives the
     text.
   - Use `Refs #NNN` when completion needs post-merge or live proof; use
     `Closes #NNN` only when the PR fully satisfies the issue.
9. Treat long PR CI as asynchronous by default.
   - Do not wait for the full matrix merely because a PR was opened.
   - Watch CI only when the user asks to merge/finish, when repairing a failing
     check, or when the touched surface makes the long check the meaningful
     proof.
   - For dependent follow-up work, prefer a stacked branch/PR over waiting for
     each intermediate PR to finish long checks.
10. Merge only when the requested gate is satisfied.
11. Cleanup merged worktrees/branches only after verifying the merge.
12. Capture a learning candidate only for reusable, evidence-backed lessons.

## Output Expectations

- Summarize the issue/source item, implementation, validation, and residual risk.
- If no test/check can reasonably be added, say why and name the manual evidence used.
- For full-loop work, include branch/PR state, CI status, merge result, cleanup,
  and whether a learning candidate was warranted.
- Keep branch and PR work targeted; avoid bundling unrelated cleanup.
- If the PR is intentionally left for asynchronous CI, say which focused checks
  passed and whether any required check was already failing.

## Repo-Specific Notes

- Preserve user-owned planning/status docs unless explicitly asked to rewrite them.
- For this git-backed flake, stage newly created files before Nix eval/build checks
  that need to see them.
- Do not include `Co-Authored-By` trailers.
