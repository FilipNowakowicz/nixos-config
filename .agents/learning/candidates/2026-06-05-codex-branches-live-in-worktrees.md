---
date: 2026-06-05
expires: 2026-07-05
status: open
agent: claude
---

# codex/* branches may be checked out in a separate worktree

**Lesson.** A `codex/*` branch can already be checked out in a linked git
worktree (e.g. under `/tmp/`). `git checkout <branch>` from the primary checkout
then fails; `cd` into the worktree path and work there instead.

**Evidence.** This session: `git checkout codex/shared-agent-workflows` →
`fatal: 'codex/shared-agent-workflows' is already used by worktree at
'/tmp/nix-shared-agent-workflows'`. Confirmed via `git worktree list`.

**When to apply.** Any task that says "work on / review branch `codex/...`"
before running `git checkout`. Check `git worktree list` first.

**Best form.** Prose — this is a workflow fact, not an enforceable repo
invariant; no test or hook can sensibly assert it.

**Proposed destination.** `CLAUDE.md` (Deploy/Environment workflow notes), one
line, only if this worktree pattern is intentional and recurring.

**Risk if wrong.** Low. If the worktree pattern is incidental, this note misleads
a future agent into looking for a worktree that does not exist — a quick
`git worktree list` disproves it.
