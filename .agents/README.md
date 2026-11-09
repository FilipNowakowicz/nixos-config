# Agent Workflow

This directory holds shared agent workflow artifacts for this repository:
skills, learning-candidate tooling, repo-map helpers, and the issue-readiness
lint in `scripts/`.

## Validation And CI Tiers

Agent workflow changes use a fast inner loop and a slower integration gate.
Do not wait on long GitHub Actions jobs as part of normal implementation unless
the task explicitly asks for merge completion or CI repair.

Use these tiers:

- **Focused local checks**: run before opening a PR. Pick the smallest commands
  that prove the changed surface, such as `bash scripts/validate.sh docs`,
  `git diff --check`, and targeted `shellcheck`.
- **PR gate**: after the PR is open, let GitHub Actions run asynchronously.
  Required branch protection and `merge-gate` remain the final merge safety net,
  but the implementation loop should move on unless a failure needs repair.
- **Full or long checks**: wait for or run these only when explicitly merging,
  finishing a large milestone, repairing CI, or touching Nix/host/profile/
  package/deploy/security surfaces where the broader check is the meaningful
  proof.

For dependent agent-workflow changes, prefer stacked PRs over waiting for each
intermediate PR to finish the full matrix. Merge the stack later in order once
the milestone is ready and the required gates are green.
