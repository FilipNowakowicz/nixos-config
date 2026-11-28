# Learning Candidates

The learning loop for the agents (Claude Code and Codex) working in this repo.
Lessons become **candidates**; once a week a reviewer model that did not write
them verifies each against the source and turns the good ones into durable
artifacts. Agents never self-edit `CLAUDE.md`, skills, hooks, or invariants from
a lesson; promotion is always a separate, reviewed step.

```
sessions --digest--> miner --+
                             +--> inbox --> reviewer --> one PR --> merge-gate
agent in a session ----------+
```

## Candidate vs. agent memory

A learning candidate is a **repo-shared, reviewed** proposal that improves the
artifacts every agent reads (checks, hooks, skills, docs). It is not the same as
an individual agent's private memory:

- Reusable lesson for **any agent working this repo** → learning candidate →
  promote to a check / hook / skill / doc.
- Cross-session context about **you and this project** (your preferences, who an
  agent is, where to navigate) → that agent's own memory store, not here.

If a fact would help a teammate's agent as much as your own, it is a candidate.

## Layout

- **Inbox** (`~/.local/state/agent-learning/inbox/`, outside git): the open
  queue, one compact YAML file per lesson (`<date>-<slug>.yml`). Keeping it out
  of git means candidates never sit uncommitted in a checkout other agents
  share. `scripts/common.sh` resolves the path (`AGENT_LEARNING_INBOX`
  overrides it).
- `candidates/archive/`: decided candidates (`promoted`, `rejected`,
  `superseded`) with a `resolution:` line, committed by the PR that decided
  them. Kept for dedup and audit.
- `TEMPLATE.yml`: the candidate format (schema v2).
- `prompts/`: the miner and reviewer prompts and their output schemas.
- `promotions/`: regression checks promoted from candidates, run by
  `scripts/validate.sh`.
- `scripts/`:
  - `file-candidate.sh` validates and files one candidate.
  - `query-candidates.sh` searches the inbox and archive by metadata, so
    agents never read the queue to dedupe.
  - `review-candidates.sh` and `check-candidate-liveness.sh` are the
    reviewer's triage: grouping, expiry, and whether the evidence already
    landed.
  - `validate-candidates.sh` and `index-candidates.sh` back the others.
  - `digest.py` and `weekly.sh` run the weekly loop.

## Schema v2

v2 adds the `tooling-wish` type: a skill, hook, check, script or subagent that
would have made the work cheaper. `cost` (optional, any type) records what its
absence cost, such as "4 failed calls in 3 sessions", so the reviewer can rank
wishes. Routes gain `promote-subagent`, and forms gain `subagent`. v1 files
still validate.

## Capture

Two sources feed the inbox:

- **The weekly miner.** `digest.py` condenses the week's Claude and Codex
  sessions in `~/nix` and its worktrees: user prompts and corrections, failed
  tool calls, commands repeated three or more times, hook blocks, and session
  size. The miner (Codex by default, Claude Sonnet as fallback, no tools) turns
  that into at most 8 candidates, deduplicated against the inbox and archive.
  It sees patterns across sessions that no single session can.
- **An agent in the moment**, through the `capture-learning-candidate` skill,
  when it holds evidence the transcript would not show well. This is optional;
  there is no Stop hook prompting for it any more. That hook used to fire in
  almost every session.

## Promotion hierarchy (read before proposing a destination)

A candidate is routed by `type`, `route`, and `best_form`. A lesson written as
prose only _asks_ a future agent to remember. A lesson written as an executable
check _makes the mistake impossible_ and stays correct because it fails loudly
when the repo changes underneath it. Prefer, in order:

1. **assertion / test / CI gate** — `lib/invariants.nix`, a NixOS assertion, a
   profile/package/smoke test, a `scripts/validate.sh` check. Self-checking:
   `merge-gate` is the reviewer.
2. **hook**: `.claude/hooks/*`, wired in both `.claude/settings.json` and
   `.codex/hooks.json` (`.agents/scripts/check-agent-sync.sh` enforces it).
3. **skill** — `.agents/skills/*`, loaded on demand by both agents.
4. **subagent** — a focused agent definition for work that would flood the
   main context (research, broad audits).
5. **CLAUDE.md prose** — last resort. Permanent context-budget tax on every
   future invocation, and no safety net if it goes stale. Reserve for genuine
   non-executable judgment.

A candidate that _could_ be executable is not allowed to propose prose.

Use `route: implement-fix` for candidates that are really backlog items, such as
"make `merge-gate` require lint." Use `promote-*` routes for agent behavior
improvements.

## Review (weekly, unattended)

The `agent-learning-weekly` user timer on `main`
([`home/profiles/agent-learning.nix`](../../home/profiles/agent-learning.nix))
runs `scripts/weekly.sh` every Friday at 10:00 (the day of the weekly
`flake.lock` update). Interactive Claude sign-ins expire, so the reviewer uses a `claude setup-token` token from
`home/users/user/secrets/agent-learning.yaml` (`claude_token`; set it with
`scripts/rotate-secret.sh set`):

1. digest and miner, as above;
2. the **reviewer**, Claude Opus with fresh context in its own worktree of
   `origin/main`, follows [`prompts/reviewer.md`](prompts/reviewer.md). It
   picks at most 8 candidates, verifies each against the source, and promotes
   (implements and validates), rejects, supersedes or defers it. It cannot
   commit, push or open PRs;
3. the script archives the decided candidates, commits, opens one PR, and
   enables auto-merge when every changed path is on the agent surface
   (`.agents/`, `.claude/`, `.codex/`, `CLAUDE.md` files, `docs/`, `tests/`).
   `merge-gate` is then the gate. A PR that touches anything else waits for the
   user. Deferred candidates stay in the inbox;
4. it posts a summary to ntfy (source "Agents").

`agent-learning-weekly --dry-run` runs only the digest and miner;
`--review-only` skips the miner. Runs keep their prompts, outputs and logs
under `~/.local/state/agent-learning/runs/` (the last 12).

The `review-learning-candidates` skill is the same review done by hand.

## Lifecycle

- Open candidates live in the inbox until reviewed. One past its `expires`
  date (90 days) shows up in `review-candidates.sh`; the reviewer re-justifies
  or rejects it.
- Decided candidates leave the inbox when their PR is opened, and land in
  `candidates/archive/` with `status` and `resolution`.

Evidence should cite a durable pointer, such as a **PR number** or a SHA on
`main`, not a local branch name. This repo squash-merges, so a pre-merge SHA
stops being an ancestor of `main`. A `#NNN` reference is what
`check-candidate-liveness.sh` can verify.
