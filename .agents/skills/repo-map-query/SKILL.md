---
name: repo-map-query
description: Use before broad repository exploration when the relevant files are not already obvious; query a compact generated repo map and open only the top likely files.
---

# Repo Map Query

Use `.agents/repo-map/scripts/query.sh` to find likely files before broad
manual exploration. This is a routing helper, not a source of truth.

## When to use

- The user asks about a repo feature and the owning files are not obvious.
- You are about to open broad docs only to discover paths.
- You are about to run a wide `rg` and then paste many results into context.
- You need to connect task words to repo areas, hosts, checks, modules, hooks,
  packages, or tests.

Skip this when the exact file is already known.

## Workflow

1. Build 2-6 concrete query terms from the task: command names, host names,
   service names, checks, modules, scripts, or error words.
2. Run `bash .agents/repo-map/scripts/query.sh <terms>`.
3. Open only the top few plausible files.
4. Verify the answer or edit against the real files.

Examples:

```sh
bash .agents/repo-map/scripts/query.sh merge-gate lint
bash .agents/repo-map/scripts/query.sh homeserver-gcp sops bootstrap
bash .agents/repo-map/scripts/query.sh waybar theme switch
```

## Guardrails

- Do not treat query output as authoritative. It only says where to look first.
- Do not add repo-map output to normal summaries unless it explains a decision.
- Keep query terms specific; vague terms like `config` or `module` produce weak
  routing.
- If the routed files don't resolve the question and broader exploration is
  still needed (many greps/reads across unfamiliar areas), prefer dispatching
  an Explore subagent and bringing back only its conclusion, rather than
  letting many raw search results accumulate in this session's transcript.
