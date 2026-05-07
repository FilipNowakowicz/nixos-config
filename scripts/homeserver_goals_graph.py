#!/usr/bin/env python3
"""Minimal LangGraph workflow for docs/homeserver-goals.md.

This script is intentionally deterministic. It shows how to model a
homeserver backlog as a graph before introducing real LLM workers.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any, Literal, TypedDict

from langgraph.graph import END, START, StateGraph


class Goal(TypedDict):
    order: int
    title: str
    difficulty: str
    status: str
    why: str
    implementation: list[str]
    acceptance: list[str]


class Task(TypedDict):
    title: str
    description: str
    owner: Literal["codex", "claude", "gemini"]
    scope: str
    validation: str


class ApprovalQuestion(TypedDict):
    question: str
    reason: str


class WorkflowState(TypedDict, total=False):
    goals_path: str
    raw_markdown: str
    goals: list[Goal]
    selected_goal: Goal
    tasks: list[Task]
    approval_required: bool
    approval_questions: list[ApprovalQuestion]
    next_action: Literal["stop_for_approval", "ready_to_execute"]
    summary: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a minimal LangGraph workflow for homeserver goals."
    )
    parser.add_argument(
        "goals_path",
        nargs="?",
        default="docs/homeserver-goals.md",
        help="Path to the goals markdown file.",
    )
    parser.add_argument(
        "--goal",
        type=int,
        default=None,
        help="Optional explicit goal order number to select.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit the final state as JSON instead of a human summary.",
    )
    return parser.parse_args()


def split_sections(raw_markdown: str) -> dict[int, str]:
    sections: dict[int, str] = {}
    pattern = re.compile(
        r"^###\s+(\d+)\.\s+(.+?)\n(.*?)(?=^###\s+\d+\.\s+|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    for match in pattern.finditer(raw_markdown):
        order = int(match.group(1))
        body = match.group(3)
        sections[order] = body
    return sections


def parse_bullets(section: str, heading: str) -> list[str]:
    pattern = re.compile(
        rf"{heading}:\n\n((?:- .+\n)+)",
        re.MULTILINE,
    )
    match = pattern.search(section)
    if not match:
        return []
    return [line[2:].strip() for line in match.group(1).strip().splitlines()]


def parse_goals_table(raw_markdown: str) -> list[Goal]:
    section_match = re.search(
        r"## Recommended Order\n\n(.*?)(?=\n## Goal Details)",
        raw_markdown,
        re.DOTALL,
    )
    if not section_match:
        raise ValueError("Could not find the 'Recommended Order' section.")

    detail_sections = split_sections(raw_markdown)
    lines = [
        line
        for line in section_match.group(1).splitlines()
        if line.strip().startswith("|")
    ]
    goals: list[Goal] = []

    for line in lines[2:]:
        parts = [part.strip() for part in line.strip().strip("|").split("|")]
        if len(parts) != 5:
            continue
        order_text, title, difficulty, status, why = parts
        if not order_text.isdigit():
            continue

        order = int(order_text)
        detail = detail_sections.get(order, "")
        goals.append(
            Goal(
                order=order,
                title=title,
                difficulty=difficulty,
                status=status,
                why=why,
                implementation=parse_bullets(detail, "Implementation"),
                acceptance=parse_bullets(detail, "Acceptance"),
            )
        )

    if not goals:
        raise ValueError("No goals were parsed from the recommended order table.")
    return goals


def classify_owner(text: str) -> Literal["codex", "claude", "gemini"]:
    lowered = text.lower()
    if any(word in lowered for word in ["document", "dashboard", "summary", "decision"]):
        return "gemini"
    if any(word in lowered for word in ["alert", "review", "validate", "threshold"]):
        return "claude"
    return "codex"


def scope_for_task(description: str) -> str:
    lowered = description.lower()
    if "terraform" in lowered or "opentofu" in lowered or "snapshot" in lowered:
        return "infra/"
    if "grafana" in lowered or "dashboard" in lowered or "alert" in lowered:
        return "modules/nixos/profiles/observability/ + docs/"
    if "nginx" in lowered or "vaultwarden" in lowered:
        return "hosts/homeserver-gcp/ + modules/nixos/"
    if "restic" in lowered or "restore" in lowered or "backup" in lowered:
        return "modules/nixos/profiles/backup.nix + docs/"
    return "docs/ + affected host/module files"


def validation_for_task(goal: Goal, description: str) -> str:
    lowered = description.lower()
    if "dashboard" in lowered or "alert" in lowered:
        return "bash scripts/validate.sh hosts"
    if "terraform" in lowered or "opentofu" in lowered or "snapshot" in lowered:
        return "terraform -chdir=infra validate"
    if "restore" in lowered or "backup" in lowered:
        return "nix build .#checks.x86_64-linux.invariants-homeserver-gcp --no-link"
    if "nginx" in lowered or "vaultwarden" in lowered:
        return "bash scripts/validate.sh hosts"
    if goal["order"] == 2:
        return "nix build .#checks.x86_64-linux.invariants-homeserver-gcp --no-link"
    return "bash scripts/validate.sh flake-eval"


def goal_requires_approval(goal: Goal) -> bool:
    risky_words = [
        "disk",
        "dns",
        "secret",
        "snapshot",
        "deploy",
        "sso",
        "auth",
        "rotation",
    ]
    haystack = " ".join(
        [goal["title"], goal["difficulty"], *goal["implementation"], *goal["acceptance"]]
    ).lower()
    return goal["difficulty"].lower() == "hard" or any(word in haystack for word in risky_words)


def make_approval_questions(goal: Goal) -> list[ApprovalQuestion]:
    questions: list[ApprovalQuestion] = []
    title = goal["title"].lower()
    if "disk" in title:
        questions.append(
            {
                "question": "Should the workflow assume the current root-only layout remains the target design?",
                "reason": "Changing storage layout can affect restore behavior and future service placement.",
            }
        )
    if "dns" in title:
        questions.append(
            {
                "question": "Should DNS remain tailnet-only even if some clients are off-tailnet?",
                "reason": "Exposure and client onboarding depend on this boundary.",
            }
        )
    if "secret" in title or "rotation" in title:
        questions.append(
            {
                "question": "Do you want the workflow to stop before changing any real secrets or only generate the rotation procedure?",
                "reason": "Documentation and live rotation should be separate approval boundaries.",
            }
        )
    if not questions and goal["difficulty"].lower() == "hard":
        questions.append(
            {
                "question": "Should this workflow stop at a plan/review stage before touching infrastructure?",
                "reason": "Hard goals usually cross multiple files or external systems.",
            }
        )
    return questions


def load_goals(state: WorkflowState) -> WorkflowState:
    goals_path = Path(state["goals_path"])
    raw_markdown = goals_path.read_text()
    goals = parse_goals_table(raw_markdown)
    return {
        **state,
        "raw_markdown": raw_markdown,
        "goals": goals,
    }


def select_goal_factory(explicit_goal: int | None):
    def select_goal(state: WorkflowState) -> WorkflowState:
        goals = state["goals"]
        if explicit_goal is not None:
            for goal in goals:
                if goal["order"] == explicit_goal:
                    return {**state, "selected_goal": goal}
            raise ValueError(f"Goal {explicit_goal} was not found in the goals file.")

        for goal in goals:
            if goal["status"].lower() == "next":
                return {**state, "selected_goal": goal}

        return {**state, "selected_goal": goals[0]}

    return select_goal


def decompose_goal(state: WorkflowState) -> WorkflowState:
    goal = state["selected_goal"]
    tasks: list[Task] = []
    for item in goal["implementation"]:
        tasks.append(
            {
                "title": item,
                "description": item,
                "owner": classify_owner(item),
                "scope": scope_for_task(item),
                "validation": validation_for_task(goal, item),
            }
        )

    if not tasks:
        tasks.append(
            {
                "title": f"Plan {goal['title']}",
                "description": f"Break down and validate the goal: {goal['title']}",
                "owner": "codex",
                "scope": "docs/ + affected host/module files",
                "validation": "bash scripts/validate.sh flake-eval",
            }
        )

    return {**state, "tasks": tasks}


def assess_risk(state: WorkflowState) -> WorkflowState:
    goal = state["selected_goal"]
    approval_required = goal_requires_approval(goal)
    return {
        **state,
        "approval_required": approval_required,
        "approval_questions": make_approval_questions(goal) if approval_required else [],
    }


def route_after_risk(state: WorkflowState) -> Literal["stop_for_approval", "ready_to_execute"]:
    if state.get("approval_required", False):
        return "stop_for_approval"
    return "ready_to_execute"


def stop_for_approval(state: WorkflowState) -> WorkflowState:
    goal = state["selected_goal"]
    return {
        **state,
        "next_action": "stop_for_approval",
        "summary": (
            f"Selected goal {goal['order']}: {goal['title']}. "
            "The workflow stopped because this goal crosses a risk boundary."
        ),
    }


def ready_to_execute(state: WorkflowState) -> WorkflowState:
    goal = state["selected_goal"]
    return {
        **state,
        "next_action": "ready_to_execute",
        "summary": (
            f"Selected goal {goal['order']}: {goal['title']}. "
            f"Prepared {len(state['tasks'])} implementation tasks."
        ),
    }


def build_graph(explicit_goal: int | None):
    graph = StateGraph(WorkflowState)
    graph.add_node("load_goals", load_goals)
    graph.add_node("select_goal", select_goal_factory(explicit_goal))
    graph.add_node("decompose_goal", decompose_goal)
    graph.add_node("assess_risk", assess_risk)
    graph.add_node("stop_for_approval", stop_for_approval)
    graph.add_node("ready_to_execute", ready_to_execute)

    graph.add_edge(START, "load_goals")
    graph.add_edge("load_goals", "select_goal")
    graph.add_edge("select_goal", "decompose_goal")
    graph.add_edge("decompose_goal", "assess_risk")
    graph.add_conditional_edges(
        "assess_risk",
        route_after_risk,
        {
            "stop_for_approval": "stop_for_approval",
            "ready_to_execute": "ready_to_execute",
        },
    )
    graph.add_edge("stop_for_approval", END)
    graph.add_edge("ready_to_execute", END)

    return graph.compile()


def print_human_summary(state: WorkflowState) -> None:
    goal = state["selected_goal"]
    print(f"Goal {goal['order']}: {goal['title']}")
    print(f"Difficulty: {goal['difficulty']}")
    print(f"Status: {goal['status']}")
    print(f"Why now: {goal['why']}")
    print()
    print("Tasks:")
    for index, task in enumerate(state["tasks"], start=1):
        print(f"{index}. {task['title']}")
        print(f"   owner: {task['owner']}")
        print(f"   scope: {task['scope']}")
        print(f"   validation: {task['validation']}")
    print()
    print(f"Next action: {state['next_action']}")
    print(state["summary"])
    if state.get("approval_questions"):
        print()
        print("Approval questions:")
        for question in state["approval_questions"]:
            print(f"- {question['question']}")
            print(f"  reason: {question['reason']}")


def main() -> None:
    args = parse_args()
    app = build_graph(args.goal)
    result = app.invoke({"goals_path": args.goals_path})
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print_human_summary(result)


if __name__ == "__main__":
    main()
