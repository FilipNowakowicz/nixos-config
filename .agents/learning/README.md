# Learning Candidates

A reviewed learning loop for the agents working in this repo. Agents capture
reusable lessons as **candidates**; a human-gated reviewer later promotes the
good ones into durable artifacts. Agents never self-edit `CLAUDE.md`, skills,
hooks, or invariants from a lesson — promotion is always a separate, reviewed
step.

```
work  ->  candidate lesson  ->  review  ->  promote  ->  better future agents
```

## Layout

- `candidates/` — open candidate notes, one file per lesson
  (`<date>-<slug>.md`). This is a staging area, not instructions; nothing here
  changes agent behavior until promoted.
- `TEMPLATE.md` — the candidate format. Copy it when capturing.

## Capture (active now)

Any agent (Claude, Codex) may drop a candidate as a side effect of normal work,
using the `capture-learning-candidate` skill. The bar is high and the act is
cheap: a candidate is a _proposal_, reviewed later, so it must never edit
instructions directly.

A shared `Stop` hook (`.claude/hooks/learning-nudge.sh`, wired for Claude in
`.claude/settings.json` and for Codex in `.codex/hooks.json`) gives a
_one-time, non-binding_ reflection prompt at the end of any session that edited
files. It asks whether a lesson is worth capturing and explicitly accepts
"nothing qualified." It never forces a candidate, fires at most once per
session, and stays silent on pure-conversation turns.

## Promotion hierarchy (read before proposing a destination)

A lesson written as prose only _asks_ a future agent to remember. A lesson
written as an executable check _makes the mistake impossible_ and stays correct
because it fails loudly when the repo changes underneath it. Prefer, in order:

1. **assertion / test / CI gate** — `lib/invariants.nix`, a NixOS assertion, a
   profile/package/smoke test, a `scripts/validate.sh` check. Self-checking:
   `merge-gate` is the reviewer.
2. **hook** — `.claude/hooks/*` (shared with Codex via `.codex/hooks.json`).
3. **skill** — `.agents/skills/*`, loaded on demand.
4. **CLAUDE.md prose** — last resort. Permanent context-budget tax on every
   future invocation, and no safety net if it goes stale. Reserve for genuine
   non-executable judgment.

A candidate that _could_ be executable is not allowed to propose prose.

## Review (added later — not yet wired)

A reviewer agent will eventually run on demand / on a schedule to:

- dedup and cluster candidates,
- reject stale or expired ones,
- **draft** the promotion in its strongest viable form (invariant > hook >
  skill > prose), and
- open a **branch/PR** for human approval — it prepares, it does not commit the
  promotion.

Until that exists, candidates simply accumulate here. That is intended.
