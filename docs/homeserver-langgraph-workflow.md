# Homeserver LangGraph Workflow

This is a minimal, deterministic LangGraph example for the homeserver backlog.
It lives in [`scripts/homeserver_goals_graph.py`](../scripts/homeserver_goals_graph.py).

It is deliberately small:

- it reads `docs/homeserver-goals.md`
- it parses the `Recommended Order` table
- it selects a goal
- it decomposes the goal into tasks
- it marks risky goals as approval gates

It does **not** call real external agents yet. The `owner` field is only a
recommendation that shows how the graph can route work later.

## Run It

```bash
python3 scripts/homeserver_goals_graph.py
```

Pick a specific goal:

```bash
python3 scripts/homeserver_goals_graph.py --goal 7
```

Emit raw state:

```bash
python3 scripts/homeserver_goals_graph.py --json
```

## How The Graph Works

The graph has six nodes:

1. `load_goals`
2. `select_goal`
3. `decompose_goal`
4. `assess_risk`
5. `stop_for_approval`
6. `ready_to_execute`

Flow:

```text
START
  -> load_goals
  -> select_goal
  -> decompose_goal
  -> assess_risk
  -> stop_for_approval | ready_to_execute
  -> END
```

`assess_risk` is the first important LangGraph idea here. It does not just
transform state; it controls which node runs next.

## What To Look At In The Code

- `WorkflowState`
  This is the shared graph state. Every node reads and writes pieces of it.

- `load_goals`
  Reads Markdown and turns it into structured `Goal` items.

- `decompose_goal`
  Converts a chosen goal into executable task records.

- `route_after_risk`
  Returns either `stop_for_approval` or `ready_to_execute`.

- `build_graph`
  Wires the nodes and edges together.

## Why This Is Useful

This gives you a real orchestrator skeleton without introducing model behavior
too early. Once this shape feels clear, the next upgrades are straightforward:

- replace task owner recommendations with real worker adapters
- save task outputs under `docs/` or `worklog/`
- add a reviewer node
- pause for real user approval on risky steps
- execute selected validations automatically

## Likely Next Step

The next practical extension is to add a node that writes the selected goal and
task list into a generated task file, for example `docs/generated/homeserver-task.md`.
That would give external agents a shared artifact to work from.
