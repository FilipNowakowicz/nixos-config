# Learning Candidates

A reviewed learning loop for the agents working in this repo. Agents capture
reusable lessons as **candidates**; a human-gated reviewer later promotes the
good ones into durable artifacts. Agents never self-edit `CLAUDE.md`, skills,
hooks, or invariants from a lesson — promotion is always a separate, reviewed
step.

```
work  ->  candidate lesson  ->  review  ->  promote  ->  better future agents
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

- `candidates/` — open candidate notes, one compact YAML file per lesson
  (`<date>-<slug>.yml`). This is a staging area, not instructions; nothing here
  changes agent behavior until promoted.
- `TEMPLATE.yml` — the compact candidate format. Copy it when capturing.
- `scripts/index-candidates.sh` — emits a TSV index from candidate metadata.
- `scripts/query-candidates.sh` — searches the index so agents do not read the
  candidate archive during capture.
- `scripts/review-candidates.sh` — groups open candidates for low-token reviewer
  triage and lists expired ones.
- `scripts/check-candidate-liveness.sh` — flags open candidates whose evidence
  already landed (PR merged / commit on HEAD), so a reviewer does not
  re-implement a done fix.
- `scripts/validate-candidates.sh` — checks required routing fields and allowed
  categories.
- `candidates/archive/` — `promoted`/`rejected`/`superseded` candidates land
  here (see [Lifecycle](#lifecycle)); the index scripts ignore it so the open
  queue stays lean.

## Capture (active now)

Any agent (Claude, Codex) may drop a candidate as a side effect of high-signal
work, using the `capture-learning-candidate` skill. The bar is high and the act
is cheap: a candidate is a structured _proposal_, reviewed later, so it must
never edit instructions directly.

A shared `Stop` hook (`.claude/hooks/learning-nudge.sh`, wired for Claude in
`.claude/settings.json` and for Codex in `.codex/hooks.json`) gives a
_one-time, non-binding_ reflection prompt only when the transcript shows both a
file edit and high-signal learning evidence such as a failed check, CI/deploy
failure, merge conflict, explicit bypass, or user correction. It asks whether a
lesson is worth capturing and explicitly accepts "nothing qualified." It never
forces a candidate, fires at most once per session, and stays silent on
pure-conversation or routine-success turns.

Capture must not scan `.agents/learning/candidates/`. Use
`scripts/query-candidates.sh` and open at most the likely duplicate candidates
that the index returns.

## Promotion hierarchy (read before proposing a destination)

A candidate is routed by `type`, `route`, and `best_form`. A lesson written as
prose only _asks_ a future agent to remember. A lesson written as an executable
check _makes the mistake impossible_ and stays correct because it fails loudly
when the repo changes underneath it. Prefer, in order:

1. **assertion / test / CI gate** — `lib/invariants.nix`, a NixOS assertion, a
   profile/package/smoke test, a `scripts/validate.sh` check. Self-checking:
   `merge-gate` is the reviewer.
2. **hook** — `.claude/hooks/*` (shared with Codex via `.codex/hooks.json`).
3. **skill** — `.agents/skills/*`, loaded on demand.
4. **CLAUDE.md prose** — last resort. Permanent context-budget tax on every
   future invocation, and no safety net if it goes stale. Reserve for genuine
   non-executable judgment.

A candidate that _could_ be executable is not allowed to propose prose.

Use `route: implement-fix` for candidates that are really backlog items, such as
"make `merge-gate` require lint." Use `promote-*` routes for agent behavior
improvements.

## Review (active on demand)

Use the `review-learning-candidates` skill when explicitly reviewing the
candidate queue. The reviewer starts from metadata:

1. run `scripts/validate-candidates.sh`,
2. run `scripts/review-candidates.sh`,
3. run `scripts/check-candidate-liveness.sh` to drop already-landed candidates,
4. choose one small batch by `route`, `best_form`, or related target,
5. open only the selected candidate files, and
6. draft or implement the promotion in the strongest viable form.

The reviewer should:

- dedup and cluster candidates,
- reject stale or expired ones,
- draft the promotion in its strongest viable form (invariant > hook >
  skill > prose),
- compact the batch into coherent PRs (executable changes in one PR, prose
  grouped by target file) rather than one PR per candidate, and
- leave promotion reviewable as a normal branch/PR.

Review remains human-gated: a candidate never changes behavior until the
promotion itself is reviewed.

## Lifecycle

`candidates/` holds only the **open** queue. The moment a candidate is resolved
its file leaves that queue, so triage never re-reads settled lessons:

- `promoted` / `rejected` / `superseded` → `git mv` into `candidates/archive/`
  in the same PR that resolves it. The index scripts (`find … -maxdepth 1`)
  skip the subdir, so the file leaves triage but stays in-tree — `rg <dedupe_key>
.agents/learning/candidates/archive/` still finds it for manual dedup/audit.
- `open` past its `expires` date → surfaced by `review-candidates.sh`; re-justify
  it or reject it. Capture is cheap precisely because stale lessons age out.

Evidence should cite a durable pointer — a **PR number** or a SHA on `main` —
not a local `codex/*` branch name. Because this repo squash-merges, a pre-merge
SHA stops being an ancestor of `main`, so a `#NNN` reference is what
`check-candidate-liveness.sh` can actually verify later.
