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
