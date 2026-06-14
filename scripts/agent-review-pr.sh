#!/usr/bin/env bash
# Reviewer entrypoint for the agent issue-to-PR loop (v2 closed loop).
#
# Reviews a PR's diff against its linked issue and emits a structured decision
# as a reviewer-evidence JSON file (schema agent-reviewer-evidence/v1, #227),
# then hands that evidence to .agents/scripts/agent-merge-gate, which applies
# the risk gate: low-risk + approved PRs can have GitHub native, CI-gated
# auto-merge enabled, while everything else is left for a human.
#
# Two modes:
#   review (default)  Scaffold evidence from the issue's acceptance criteria,
#                     run a reviewer model (`claude -p`) to fill it from the PR
#                     diff + issue, validate it via agent-review-stage, post a
#                     summary comment, and run the merge gate.
#   --decision-only   Skip the model: take an already-filled --evidence file,
#                     (optionally) post it, and run the merge gate. Offline-
#                     friendly with --files-from; used by the self-test.
#
# SAFETY: this never merges directly, never pushes to a base branch, and never
# uses `gh pr merge --admin`. Merge authority is GitHub native auto-merge gated
# by `merge-gate` (enabled only with --enable-auto-merge on an "auto" decision).
set -euo pipefail

AGENT_CLAUDE_CMD="${AGENT_CLAUDE_CMD:-claude}"
AGENT_REVIEW_MODEL="${AGENT_REVIEW_MODEL:-}"

usage() {
  cat <<'EOF'
Usage: agent-review-pr.sh --pr <n> [--issue <n>] [--enable-auto-merge]
                          [--no-comment] [--out <path>]
       agent-review-pr.sh --decision-only --evidence <path>
                          (--pr <n> | --files-from <path>) [--enable-auto-merge]
       agent-review-pr.sh --self-test

Review a PR against its linked issue, emit reviewer evidence, and run the
risk-gated merge gate.

Options:
  --pr <n>             PR number to review.
  --issue <n>          Linked issue number. Default: discovered from the PR's
                       closing references / body.
  --evidence <path>    review mode: output path for the evidence JSON
                       (default: .agents/state/review/issue-<i>-pr-<n>.json).
                       --decision-only: the pre-filled evidence file to use.
  --decision-only      Skip the reviewer model; use an existing --evidence file
                       and run the merge gate only.
  --files-from <path>  --decision-only: changed-paths source forwarded to the
                       merge gate ("-" for stdin). Offline; never calls GitHub.
  --enable-auto-merge  On an "auto" gate decision, enable GitHub native auto-
                       merge (still gated by merge-gate). Default: dry-run.
  --no-comment         Do not post the review summary as a PR comment.
  --out <path>         Alias for --evidence in review mode.
  --self-test          Run a deterministic, offline self-test and exit.
  -h, --help           Show this help.

Environment:
  AGENT_CLAUDE_CMD     Claude CLI command (default: claude).
  AGENT_REVIEW_MODEL   Optional model override passed to the reviewer session.
EOF
}

die() {
  printf 'agent-review-pr: %s\n' "$*" >&2
  exit 2
}

script_dir() {
  CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

repo_root() {
  CDPATH='' cd -- "$(script_dir)/.." && pwd
}

review_stage_bin() {
  printf '%s/.agents/scripts/agent-review-stage\n' "$(repo_root)"
}

merge_gate_bin() {
  printf '%s/.agents/scripts/agent-merge-gate\n' "$(repo_root)"
}

# Best-effort discovery of the issue a PR closes: prefer GitHub's structured
# closingIssuesReferences, fall back to a closing keyword in the PR body.
discover_linked_issue() {
  local pr="$1" issue
  issue=$(gh pr view "$pr" --json closingIssuesReferences \
    --jq '.closingIssuesReferences[0].number // empty' 2>/dev/null || true)
  if [[ -z $issue ]]; then
    issue=$(gh pr view "$pr" --json body --jq '.body // ""' 2>/dev/null |
      grep -oiE '(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]+#[0-9]+' |
      grep -oE '[0-9]+' | head -n1 || true)
  fi
  printf '%s' "$issue"
}

build_review_prompt() {
  local pr="$1" issue="$2" evidence="$3"
  cat <<EOF
You are the reviewer stage of an autonomous issue-to-PR loop. Review pull
request #${pr} against its linked issue #${issue} and emit a structured
decision. Do NOT merge the PR, do NOT push to any branch, and do NOT edit
repository files other than the evidence file named below.

Steps:
1. Read the issue with: gh issue view ${issue} --json title,body
2. Read the PR metadata and diff with: gh pr view ${pr} ; gh pr diff ${pr}
3. Judge whether the diff satisfies every "## Acceptance criteria" bullet,
   whether validation evidence is credible, and whether any changed path is
   security/deploy/host-state sensitive.
4. Overwrite ${evidence} with a schema-valid agent-reviewer-evidence/v1 JSON:
   - result: "approved" only if every acceptance criterion is met with concrete
     evidence and no protected path is touched; "changes_requested" if fixable
     gaps remain; "blocked" if you cannot evaluate it.
   - acceptance_criteria[]: one entry per issue criterion, each with concrete
     evidence (what in the diff satisfies it), not a placeholder.
   - validation_commands[]: the checks the PR ran and their results.
   - residual_risk: the honest residual risk if this merged.
5. Validate your file with:
   bash .agents/scripts/agent-review-stage check ${evidence} --issue ${issue}
   Fix it until that check passes.

Merge authority is decided downstream by agent-merge-gate; your only job is an
honest, schema-valid decision. Keep output terse: do not paste full diffs or
build logs into the conversation.
EOF
}

post_pr_comment() {
  local pr="$1" evidence="$2"
  command -v gh >/dev/null 2>&1 || return 0
  local result tmp
  result=$(jq -r '.result' "$evidence" 2>/dev/null || printf 'unknown')
  tmp=$(mktemp)
  # shellcheck disable=SC2016  # literal backticks render `code` in the Markdown comment
  {
    printf '## Agent reviewer decision: `%s`\n\n' "$result"
    printf 'Automated reviewer-stage evidence (advisory; `merge-gate` remains the gate).\n\n'
    printf '**Residual risk:** %s\n\n' "$(jq -r '.residual_risk // "n/a"' "$evidence")"
    printf '| Acceptance criterion | Evidence |\n| --- | --- |\n'
    jq -r '.acceptance_criteria[]? | "| " + (.criterion | gsub("\\|";"\\\\|")) + " | " + (.evidence | gsub("\\|";"\\\\|")) + " |"' "$evidence"
  } >"$tmp"
  if gh pr comment "$pr" --body-file "$tmp" >/dev/null 2>&1; then
    echo "agent-review-pr: posted reviewer decision comment to PR #$pr" >&2
  else
    echo "agent-review-pr: failed to post reviewer comment to PR #$pr" >&2
  fi
  rm -f "$tmp"
}

run_gate() {
  local pr="$1" evidence="$2" enable="$3" files_from="$4" json="$5"
  local gate
  gate="$(merge_gate_bin)"
  [[ -x $gate ]] || die "agent-merge-gate not found or not executable: $gate"
  local -a args=(--evidence "$evidence")
  if [[ -n $files_from ]]; then
    args+=(--files-from "$files_from")
  else
    args+=(--pr "$pr")
  fi
  [[ $enable -eq 1 ]] && args+=(--enable)
  [[ $json -eq 1 ]] && args+=(--json)
  "$gate" "${args[@]}"
}

run() {
  local pr="" issue="" evidence="" decision_only=0 enable=0 comment=1 files_from="" json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --pr)
      pr="${2:?--pr needs a value}"
      [[ $pr =~ ^[0-9]+$ ]] || die "--pr must be a positive integer"
      shift 2
      ;;
    --issue)
      issue="${2:?--issue needs a value}"
      [[ $issue =~ ^[0-9]+$ ]] || die "--issue must be a positive integer"
      shift 2
      ;;
    --evidence | --out)
      evidence="${2:?--evidence needs a value}"
      shift 2
      ;;
    --files-from)
      files_from="${2:?--files-from needs a value}"
      shift 2
      ;;
    --decision-only)
      decision_only=1
      shift
      ;;
    --enable-auto-merge)
      enable=1
      shift
      ;;
    --no-comment)
      comment=0
      shift
      ;;
    --json)
      json=1
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
    esac
  done

  command -v jq >/dev/null 2>&1 || die "jq not found"

  if [[ $decision_only -eq 1 ]]; then
    [[ -n $evidence ]] || die "--decision-only requires --evidence"
    [[ -f $evidence ]] || die "evidence file not found: $evidence"
    [[ -n $pr || -n $files_from ]] || die "--decision-only requires --pr or --files-from"
    [[ $comment -eq 1 && -n $pr && -z $files_from ]] && post_pr_comment "$pr" "$evidence"
    run_gate "$pr" "$evidence" "$enable" "$files_from" "$json"
    return $?
  fi

  # Review mode: needs GitHub + a model.
  [[ -n $pr ]] || die "--pr is required (see --help)"
  command -v gh >/dev/null 2>&1 || die "gh not found"
  command -v "$AGENT_CLAUDE_CMD" >/dev/null 2>&1 || die "$AGENT_CLAUDE_CMD CLI not found"

  if [[ -z $issue ]]; then
    issue=$(discover_linked_issue "$pr")
    [[ -n $issue ]] || die "could not discover a linked issue for PR #$pr; pass --issue"
    echo "agent-review-pr: PR #$pr linked to issue #$issue" >&2
  fi

  local stage
  stage="$(review_stage_bin)"
  [[ -x $stage ]] || die "agent-review-stage not found or not executable: $stage"

  evidence="${evidence:-.agents/state/review/issue-${issue}-pr-${pr}.json}"
  mkdir -p "$(dirname "$evidence")"
  "$stage" init --issue "$issue" --pr "$pr" --out "$evidence" >/dev/null ||
    die "failed to scaffold reviewer evidence for issue #$issue / PR #$pr"
  echo "agent-review-pr: scaffolded evidence at $evidence" >&2

  local prompt
  prompt=$(build_review_prompt "$pr" "$issue" "$evidence")
  local -a claude_args=(-p "$prompt" --output-format stream-json --verbose)
  [[ -n $AGENT_REVIEW_MODEL ]] && claude_args+=(--model "$AGENT_REVIEW_MODEL")
  echo "agent-review-pr: running reviewer session for PR #$pr ..." >&2
  "$AGENT_CLAUDE_CMD" "${claude_args[@]}" || die "reviewer session failed; inspect $evidence"

  "$stage" check "$evidence" --issue "$issue" ||
    die "reviewer evidence failed validation; not gating PR #$pr"

  [[ $comment -eq 1 ]] && post_pr_comment "$pr" "$evidence"
  run_gate "$pr" "$evidence" "$enable" "" "$json"
}

self_test() {
  local tmp script_path out
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  script_path="$(script_dir)/$(basename "${BASH_SOURCE[0]}")"

  # Safety invariant: no actual `gh pr merge` command anywhere in this script.
  if grep -nE '^[[:space:]]*gh +pr +merge' "$script_path"; then
    die "self-test: this script must not run 'gh pr merge' directly (merge authority is agent-merge-gate)"
  fi

  local approved="$tmp/approved.json" changes="$tmp/changes.json"
  cat >"$approved" <<'EOF'
{
  "schema": "agent-reviewer-evidence/v1",
  "issue": 284,
  "pr": 9001,
  "result": "approved",
  "acceptance_criteria": [
    {"criterion": "low-risk change", "evidence": "docs only"}
  ],
  "validation_commands": [
    {"command": "bash scripts/validate.sh docs", "result": "passed"}
  ],
  "residual_risk": "Docs-only; CI gate still required."
}
EOF
  jq '.result = "changes_requested"' "$approved" >"$changes"

  local low="$tmp/low.txt" high="$tmp/high.txt"
  printf 'docs/architecture.md\n' >"$low"
  printf '.sops.yaml\n' >"$high"

  # decision-only, low-risk + approved -> gate decides auto (dry-run, offline).
  out=$("$script_path" --decision-only --evidence "$approved" --files-from "$low" --json)
  jq -e '.decision == "auto"' <<<"$out" >/dev/null ||
    die "self-test: expected low-risk+approved decision-only to be auto (got: $out)"

  # decision-only, high-risk path -> human.
  out=$("$script_path" --decision-only --evidence "$approved" --files-from "$high" --json)
  jq -e '.decision == "human"' <<<"$out" >/dev/null ||
    die "self-test: expected high-risk decision-only to be human (got: $out)"

  # decision-only, changes_requested evidence -> human.
  out=$("$script_path" --decision-only --evidence "$changes" --files-from "$low" --json)
  jq -e '.decision == "human"' <<<"$out" >/dev/null ||
    die "self-test: expected changes_requested decision-only to be human (got: $out)"

  # --decision-only without --evidence is rejected.
  if "$script_path" --decision-only --files-from "$low" >/dev/null 2>&1; then
    die "self-test: expected --decision-only without --evidence to fail"
  fi

  printf 'agent-review-pr self-test passed\n'
}

main() {
  case "${1:-}" in
  --self-test)
    self_test
    exit 0
    ;;
  -h | --help | "")
    usage
    [[ ${1:-} == "" ]] && exit 2
    exit 0
    ;;
  *)
    run "$@"
    ;;
  esac
}

main "$@"
