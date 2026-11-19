---
name: release-cleanup
description: Use after merging one or more ready PRs to finalize and ship a release — merge remaining ready PRs, cut or update the release tag, write real release notes, delete fully-merged branches, and verify a clean final state.
---

# Release Cleanup

Use this when the user asks to "wrap up", "clean everything up", "ship it", or
"finish the release" after a round of fixes has landed via PR. It closes the
loop from merged code to a tagged, documented release with no stray branches
left behind — especially relevant after an iterative bug-chasing session that
produced several small follow-up PRs against the same release.

## Workflow

1. Confirm state before changing anything:
   - `git status --short` — clean, or stash/ask about uncommitted work.
   - `gh pr list --state open` — merge any that are ready and the user
     expects merged; do not merge one that's still under discussion or
     failing CI without asking.
   - Poll `gh pr view <n> --json mergeStateStatus` and wait out a `BLOCKED`
     state that's just CI still running, rather than force-merging past it.
2. Decide the release action — don't assume:
   - If the project tags releases and CI builds/publishes on tag push, ask
     (if it's not obvious from how the user phrased the request) whether
     this batch should recut the existing in-flight tag or bump to a new
     version.
   - To recut an existing tag: delete the GitHub release
     (`gh release delete <tag> --yes`), delete the remote tag
     (`git push origin :refs/tags/<tag>`), delete the local tag, then
     re-create it on the new commit (`git tag -a <tag> <sha> -m <tag>`) and
     push it.
   - To bump instead: follow the project's own version-bump convention
     (e.g. a dedicated commit bumping a version string) before tagging.
3. Write real release notes, not a raw commit log:
   - Group changes by theme (fixes vs. new tooling vs. speculative/unverified
     changes) rather than listing commits flatly.
   - Call out anything unverified or speculative explicitly, matching
     whatever convention the target repo already uses for that (e.g. an
     "UNVERIFIED as of &lt;date&gt;" marker), instead of presenting it as
     confirmed.
   - `gh release edit <tag> --notes-file <file>` (or `--notes`) once the
     release exists.
4. Clean up branches only after confirming they're merged:
   - For each branch touched this session, verify
     `git merge-base --is-ancestor <branch> <default-branch>` before
     deleting anything — never delete on assumption.
   - GitHub often auto-deletes a PR's remote head branch on merge already;
     check with `git ls-remote --heads origin` before assuming a
     `git push origin --delete` is still needed.
   - Prune stale local tracking refs (`git remote prune origin`) and delete
     local branch copies (`git branch -D <branch>`) only for branches
     confirmed merged.
   - Leave alone any branch that predates the current session or isn't
     merged — investigate rather than delete work you don't recognize.
5. Verify the final state and report it back concisely:
   - `gh pr list --state open` (expect none left from this batch).
   - `git status --short` (clean).
   - `git log --oneline -1` on the default branch.
   - The release/tag URL.

## Guardrails

- Force-pushing a moved tag and deleting a published GitHub release are
  destructive to anyone who already pulled/downloaded from them — only do
  this when the user has explicitly asked to update/recut that same
  release, not as a default way to fix a mistake.
- Never delete a branch without first verifying it's merged into the target
  branch; "the PR was merged" is not the same as "this exact branch/SHA is
  an ancestor of the default branch" if history was rewritten in between.
- Don't invent a version bump or release cadence the project doesn't already
  use — check existing tags/CHANGELOG conventions first.

## Output Expectations

- Report which PRs were merged, whether a tag was recut or newly created
  (and why), a link to the release, which branches were deleted vs. left
  alone, and confirmation of a clean final `git status`.
