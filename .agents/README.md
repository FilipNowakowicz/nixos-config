# Agent Workflow

This directory holds shared agent workflow artifacts for this repository:
skills, learning-candidate tooling, repo-map helpers, schemas, scripts, and
runtime state.

## Outcome Records

`scripts/agent-run-issue.sh` writes one outcome record per issue session through
`.agents/scripts/agent-record-outcome`. Records use
`.agents/schemas/outcome.schema.json` and default to:

```text
.agents/state/outcomes/<timestamp>-issue-<number>-<status>.json
```

Runtime outcome records are intentionally ignored by git. They are telemetry for
operators and later automation, not reviewed repo instructions.

When issues run through `scripts/agent-session.sh --issues`, the workstation
collects remote `.agents/state/outcomes/*.json` records after the SSH command
returns. It also copies any missing `.agents/learning/candidates/*.yml` files
from the worker into the local candidate queue without overwriting existing
files.

Useful inspection commands:

```sh
jq -r '[.issue, .status, (.prs | map("#" + (.number|tostring)) | join(",")), (.learning_candidates | length)] | @tsv' .agents/state/outcomes/*.json
jq '.git_dirty, .learning_candidates, .blocker' .agents/state/outcomes/<record>.json
```

To summarize many records at once — issue, status, exit code, PR
count/numbers/urls, started/finished timestamps, and blocker — without opening
each JSON file, use `.agents/scripts/agent-outcome-index`:

```sh
.agents/scripts/agent-outcome-index               # TSV table from .agents/state/outcomes
.agents/scripts/agent-outcome-index --json        # JSON array, e.g. for dashboards
.agents/scripts/agent-outcome-index --dir <path>  # scan a different outcome directory
```

Malformed or schema-invalid records are reported on stderr and cause a
non-zero exit; pass `--permissive` to report them without failing.

Outcome records are separate from learning candidates:

- outcome records describe what happened in one run;
- learning candidates propose durable repo improvements;
- only reviewed PRs promote candidates into behavior-changing artifacts.

For a human-readable rollup of a time window — PRs referenced by outcomes,
blocked issues, failed validations, learning candidates captured, run
durations, and a "human decisions needed" summary — use
`.agents/scripts/agent-weekly-digest`:

```sh
.agents/scripts/agent-weekly-digest                          # all recorded outcomes
.agents/scripts/agent-weekly-digest --since 2026-06-01        # only records since this date
.agents/scripts/agent-weekly-digest --dir <path>               # scan a different outcome directory
.agents/scripts/agent-weekly-digest --candidates-dir <path>    # scan a different candidates directory
```

It reads the same `agent-outcome/v1` schema assumptions as
`agent-outcome-index` directly (so PR state/title and learning-candidate paths
remain available) and is read-only: it does not file issues, post comments,
merge PRs, or estimate cost/token totals beyond fields already present in
outcome records.

## Validation And CI Tiers

Agent workflow changes use a fast inner loop and a slower integration gate.
Do not wait on long GitHub Actions jobs as part of normal implementation unless
the task explicitly asks for merge completion or CI repair.

Use these tiers:

- **Focused local checks**: run before opening a PR. Pick the smallest commands
  that prove the changed surface, such as `bash scripts/validate.sh docs`,
  a new `--self-test`, `git diff --check`, and targeted `shellcheck`.
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

## Liveness Gate

Before dispatching a batch of issues to `scripts/agent-run-issue.sh` (e.g. via
`scripts/agent-session.sh --issues`), run
`.agents/scripts/agent-liveness-gate` to catch a broken cold-start
environment before it burns a session. It checks that the runner's required
commands (`git`, `gh`, `jq`, `claude`) are on `PATH`, that `gh auth status`
succeeds, and that the cheap, deterministic self-tests of
`agent-issue-readiness`, `agent-record-outcome`, and `agent-outcome-index` all
pass:

```sh
.agents/scripts/agent-liveness-gate                # full preflight
.agents/scripts/agent-liveness-gate --skip-gh-auth # before the scoped PAT is provisioned
.agents/scripts/agent-liveness-gate --self-test    # gate's own self-test (run via scripts/validate.sh docs)
```

It is opt-in and read-only: it does not perform live agent dispatch and
requires no secrets, sudo, or remote host access beyond what `gh auth status`
itself needs.

## Dispatcher Skeleton

`.agents/scripts/agent-dispatch` is an opt-in, maintainer-label-gated
dispatcher skeleton. It selects open issues labeled `agent:ready` (excluding
any also labeled `agent:not-ready` or `agent:blocked`), runs the liveness gate
once, runs the issue-readiness check on each candidate, and dispatches ready
issues one at a time to `scripts/agent-run-issue.sh --require-ready`:

```sh
.agents/scripts/agent-dispatch --dry-run                 # list eligible issues only
.agents/scripts/agent-dispatch --max-issues 1            # dispatch up to 1 ready issue
.agents/scripts/agent-dispatch --self-test               # local fixtures only (run via scripts/validate.sh docs)
```

Issues that fail the pre-dispatch readiness check are not dispatched; a
`blocked` outcome record with a fixed blocker reason is written instead via
`.agents/scripts/agent-record-outcome`, without burning a session.
`--max-concurrent` must be `1` — higher concurrency is out of scope for this
skeleton. The dispatcher only ever selects the maintainer-owned `agent:ready`
label; it does not run on a timer, grant auto-merge authority, or change how
`scripts/agent-run-issue.sh` itself operates.

## Issue Runner Bounds

`scripts/agent-run-issue.sh` supervises each inner Claude issue session with
cheap, deterministic guardrails:

```sh
AGENT_INNER_TIMEOUT_SECONDS=900   # default; 0 disables the timeout
AGENT_HEARTBEAT_SECONDS=60        # default; 0 disables heartbeat lines
AGENT_INNER_KILL_GRACE_SECONDS=15 # TERM grace period before KILL
```

Heartbeat lines go to stderr while the inner process is alive and include
elapsed seconds plus the current git branch and dirty-file count. If the timeout
is exceeded, the runner terminates the inner process group, records a failure
outcome with a timeout blocker, and moves on according to the normal issue-loop
rules.

For dogfood batches, keep the defaults or lower the timeout for tiny issues.
Raise it only when the issue explicitly needs a long validation/build phase.
`scripts/agent-run-issue.sh --self-test` covers timeout supervision with local
fixture workers; it does not invoke a real model.

Fresh clones also get a push-safe `origin` remote. If the runner sees a standard
GitHub HTTPS push URL such as `https://github.com/owner/repo.git`, it configures
the push URL as `git@github.com:owner/repo.git` before issue work begins. This
avoids completing a session and failing only at PR publication because an
interactive HTTPS credential prompt was unavailable. Existing SSH remotes and
non-GitHub HTTPS remotes are left unchanged.

## Governance Policy

`.agents/governance.yaml` is a versioned, advisory policy that classifies
changed repository paths by risk and whether they require human review.
`.agents/scripts/agent-policy-eval` evaluates a set of changed paths against
it:

```sh
git diff --name-only main... | .agents/scripts/agent-policy-eval
.agents/scripts/agent-policy-eval --git-diff main          # read changed paths from git
.agents/scripts/agent-policy-eval --json --git-diff main   # JSON output
.agents/scripts/agent-policy-eval --self-test              # self-test (run via scripts/validate.sh docs)
```

It exits non-zero if any changed path requires human review (e.g. secrets,
`.sops.yaml`, `.github/workflows/**`, or the governance policy/evaluator
itself). This is a deterministic foundation for later autonomy policy, not an
auto-merge system: nothing currently acts on its exit code, and it is not
wired into branch protection.

## Reviewer Evidence

`.agents/schemas/reviewer-evidence.schema.json` defines the local JSON shape for
structured PR review evidence. `.agents/scripts/agent-review-evidence-check`
validates one evidence file without GitHub API calls:

```sh
.agents/scripts/agent-review-evidence-check review-evidence.json
.agents/scripts/agent-review-evidence-check --self-test # run via scripts/validate.sh docs
```

Minimal evidence:

```json
{
  "schema": "agent-reviewer-evidence/v1",
  "issue": 227,
  "pr": 999,
  "result": "approved",
  "acceptance_criteria": [
    {
      "criterion": "scripts/validate.sh docs runs the validator self-test",
      "evidence": "bash scripts/validate.sh docs exited 0"
    }
  ],
  "validation_commands": [
    {
      "command": "bash scripts/validate.sh docs",
      "result": "passed"
    }
  ],
  "residual_risk": "Evidence is advisory until later automation consumes it."
}
```

This evidence sits between implementation and merge review in the issue-to-PR
loop. It gives future automation deterministic fields to inspect, but it does
not grant merge authority or replace human review.

### Reviewer Stage

`.agents/scripts/agent-review-stage` is a structured reviewer-stage skeleton
built on top of `agent-review-evidence-check`. It has two modes:

```sh
# Scaffold reviewer evidence for an issue/PR pair from the issue's
# "## Acceptance criteria" bullets. Written under .agents/state/review/, an
# ignored runtime state path (not repo policy).
.agents/scripts/agent-review-stage init --issue 227 --pr 999

# Validate a (possibly hand-edited) evidence file: schema + required fields
# via agent-review-evidence-check, every acceptance-criteria bullet from the
# issue has matching evidence (unless the overall result is "blocked" or
# "changes_requested" — an explicit blocker), and — if given the PR's changed
# paths — an "approved" result is rejected when agent-policy-eval says any
# changed path requires human review.
.agents/scripts/agent-review-stage check .agents/state/review/issue-227-pr-999.json \
  --issue 227 --git-diff main

.agents/scripts/agent-review-stage --self-test  # local fixtures only (run via scripts/validate.sh docs)
```

`agent-review-stage` produces a **recommendation only**. A non-zero exit
means "blocked" — invalid evidence, missing acceptance-criteria coverage for
an "approved" result, or an "approved" result on paths
`.agents/scripts/agent-policy-eval` says require human review. It does not
call a real model, auto-merge PRs, override `.agents/governance.yaml` or
`agent-policy-eval`, or otherwise decide autonomy policy — those remain
separate, human-reviewed gates.

## Routing Metadata

`.agents/model-routing.yaml` and `.agents/capability-profiles.yaml` define the
first advisory routing substrate for agent work. They describe path classes,
risk tiers, default capability profiles, required checks, and escalation rules
for docs, agent workflow scripts, Nix modules, security/secrets, and
CI/workflow changes.

Validate the metadata locally:

```sh
.agents/scripts/agent-routing-check
.agents/scripts/agent-routing-check --self-test # run via scripts/validate.sh docs
```

`.agents/scripts/agent-route` classifies a set of changed paths against this
metadata and emits a route decision: matched path classes, an overall risk
tier, a default capability profile, and the union of required checks. A path
matching no declared class, or any path class whose required checks include
"human review" (security-secrets, ci-workflows), routes to `human-review` with
no default profile — a human-review route never selects an auto-executable
profile.

```sh
.agents/scripts/agent-route --git-diff main          # table for paths changed vs. main
.agents/scripts/agent-route --git-diff main --json   # full route-decision JSON
.agents/scripts/agent-route --self-test              # run via scripts/validate.sh docs
```

`scripts/agent-run-issue.sh` computes a route decision for the paths changed
during each issue session (relative to `$BASE_BRANCH`) and embeds it under
`route` in that session's outcome record via
`.agents/scripts/agent-record-outcome --route-file`. This is **advisory
execution metadata only**: it does not select models, grant merge authority, or
change branch protection. It exists so outcome records carry a reviewed,
deterministic risk/profile classification of what an agent touched, for later
dispatcher integration and human review.

## Dispatch Eligibility

This repository is public with GitHub Issues enabled, so anyone can file an
issue. Filing an issue, choosing its title/body/author, or applying ordinary
labels grants **no** automated-dispatch authority. The only label that does is
`agent:ready`, and only a maintainer applies it.

`agent:ready` is the default queue label for `scripts/agent-run-issue.sh
--label <label>` and any future dispatcher. An issue is dispatch-eligible only
if it carries `agent:ready` AND does not also carry `agent:not-ready` or
`agent:blocked` — either of those excludes it even if `agent:ready` is also
present, since a maintainer may add either to an in-flight issue without
remembering to remove `agent:ready`.

`.agents/scripts/agent-dispatchable-issues` computes this set deterministically
from `gh issue list`:

```sh
.agents/scripts/agent-dispatchable-issues             # eligible issue numbers, one per line
.agents/scripts/agent-dispatchable-issues --json      # full {number,title,labels} objects
.agents/scripts/agent-dispatchable-issues --label custom-label
.agents/scripts/agent-dispatchable-issues --self-test # run via scripts/validate.sh docs
```

Feed its output to `scripts/agent-run-issue.sh` for batch dispatch, e.g.:

```sh
.agents/scripts/agent-dispatchable-issues | xargs -r scripts/agent-run-issue.sh
```

This is a read-only filter, not the dispatcher itself: it does not invoke
Claude, open PRs, or change labels.
