---
name: review-learning-candidates
description: Use when reviewing accumulated .agents/learning candidates, deduplicating them, rejecting weak ones, or promoting strong ones into executable checks, hooks, skills, or docs.
---

# Review Learning Candidates

Review compact learning candidates under `.agents/learning/candidates/`.
Candidate review is explicit, batch-oriented work. Do not run it as part of
normal task wrap-up.

End state of a review pass: every candidate touched is either implemented in a
PR (and `promoted`), `superseded`, `rejected`, or consciously left `open` with a
reason. The promotion and the candidate's `status` flip travel together in the
same branch, and `promoted`/`rejected`/`superseded` files are moved out of the
open queue so the index stays lean.

## Goal

Turn candidate proposals into the strongest useful repo artifact:

1. assertion / test / CI gate
2. hook
3. skill
4. doc
5. rejection

Prefer executable enforcement over prose. A candidate that can become a check,
test, or invariant should not be promoted to `CLAUDE.md`.

## Workflow

### 1. Triage from metadata

1. Run `bash .agents/learning/scripts/validate-candidates.sh`.
2. Run `bash .agents/learning/scripts/review-candidates.sh` — read status counts,
   the route/form grouping, and the **Expired open candidates** list.
3. Run `bash .agents/learning/scripts/check-candidate-liveness.sh` — it flags
   open candidates whose evidence already landed (PR merged / commit on HEAD).
4. Choose a small batch by `route`, `best_form`, or related `targets`. Open only
   the candidate files in that batch.

### 2. Decide one outcome per candidate

Resolve liveness first: if `check-candidate-liveness.sh` reports **LIKELY
RESOLVED**, or you confirm by hand that the fix already landed, the route is
moot — mark it `superseded` and do not re-implement. `NO SIGNAL` is not a clean
bill of health (the evidence just lacks a pointer); judge it from evidence and
targets. Treat an `implement-fix` candidate as "is a fix still needed?", never
as "a fix is owed" — the fix is often already in tree.

For everything that still needs action:

- `implement-fix`: implement the repo fix, or leave it as explicit backlog if
  the user only asked for triage.
- `promote-hook`: update a hook and validate it with direct hook tests.
- `promote-skill`: update or create a skill and validate any helper scripts.
- `promote-doc`: update the smallest relevant doc only if no stronger form fits.
- `promote-memory`: use only for low-drift repo navigation or preference facts
  that are too broad for a skill or check.
- `reject`: mark stale, duplicate, unsupported, or low-signal candidates.

### 3. Compact the batch into PRs

Do not open one PR per candidate. Group the decided work so each PR is a single
coherent unit:

- **One PR for executable changes** (invariant / test / CI gate / hook /
  validator script). These are self-checking via `merge-gate` and deserve to be
  reviewed apart from prose.
- **Separate PR(s) for prose** (skill / doc), grouped by the file they touch —
  e.g. all `nix-verification-loop` skill additions together, all
  `docs/operations.md` additions together.

Keep PRs off `main` (branch first) and conflict-free: group so two open PRs
never edit the same file. If a candidate's promotion needs validation, use the
`nix-verification-loop` skill to pick the smallest meaningful check.

### 4. Bookkeep in the same branch

In the PR that implements a promotion, also:

- flip the candidate `status` (`promoted` / `rejected` / `superseded`), and
- **archive the file**: `git mv` it from `candidates/` to `candidates/archive/`.
  The index scripts only scan `candidates/` at depth 1, so archiving drops it
  from the open queue automatically while preserving the dedupe_key, evidence,
  and promotion target for future dedup queries.

`status` values:

- `promoted` — implemented in this branch.
- `rejected` — no durable action should be taken.
- `superseded` — another candidate or artifact (often an already-merged fix)
  covers it.
- `open` — still needs later work; leave it in `candidates/` (do not archive).

## Guardrails

- Do not scan the whole candidate directory before choosing a batch from the
  metadata index.
- Do not promote more than one unrelated batch at once unless the user asks.
- Do not put secrets, host credentials, or transient session facts into docs or
  memory.
- If promotion changes repo behavior, use the `nix-verification-loop` skill to
  pick the smallest meaningful validation.
- Review stays human-gated: the promotion PR is the gate. Do not enable
  auto-merge or merge it yourself unless the user asks.
