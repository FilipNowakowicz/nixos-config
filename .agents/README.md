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
