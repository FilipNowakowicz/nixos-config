---
name: issue-driven-development
description: Use when turning a GitHub issue, review finding, roadmap item, or bug report into a scoped implementation with acceptance criteria and tests.
---

# Issue-Driven Development

Use this workflow for non-trivial implementation work, especially when the task
starts from an issue, review finding, CI failure, roadmap item, or vague bug.

## Workflow

1. Establish the source item:
   - GitHub issue/PR review comment, local review note, roadmap entry, CI failure,
     or user-stated bug.
2. Restate the acceptance criteria in concrete terms:
   - What behavior changes?
   - What must not change?
   - What command/check will prove completion?
3. Create or identify the failing check before editing when feasible:
   - Nix invariant, fixture, package check, profile test, smoke test, doc-link check,
     or a narrow command from `scripts/validate.sh`.
4. Implement the smallest durable repo-side fix.
5. Run the acceptance check, then any broader validation justified by the touched surface.
6. Update the source item or local status artifact only when the task requires it.

## Output Expectations

- Summarize the issue/source item, implementation, validation, and residual risk.
- If no test/check can reasonably be added, say why and name the manual evidence used.
- Keep branch and PR work targeted; avoid bundling unrelated cleanup.

## Repo-Specific Notes

- Preserve user-owned planning/status docs unless explicitly asked to rewrite them.
- For this git-backed flake, stage newly created files before Nix eval/build checks
  that need to see them.
- Do not include `Co-Authored-By` trailers.

