#!/usr/bin/env bash
# Issue-loop orchestration entrypoint — runs ON gcp-agent.
#
# Given a target issue number (or a label filter), it drives the
# issue-driven-development skill from a cold, up-to-date clone through to a
# pushed PR, then returns and lets the idle-shutdown timer power the box off.
#
# Typical invocation from a workstation (starts the VM, then runs this on it):
#   scripts/agent-session.sh -- nix/scripts/agent-run-issue.sh 169
#   scripts/agent-session.sh -- nix/scripts/agent-run-issue.sh --label agent-ready
#
# Or directly, once SSH'd into gcp-agent:
#   scripts/agent-run-issue.sh 169 170
#   scripts/agent-run-issue.sh --label architecture-review
#
# Env knobs:
#   AGENT_REPO_DIR  repo clone to operate in (default: $HOME/nix)
#   BASE_BRANCH     branch to sync to before each issue (default: main)
#   REPO_URL        HTTPS clone URL used to bootstrap AGENT_REPO_DIR when it
#                    does not exist yet (default: this repo, via gh's PAT)
#   AGENT_OUTCOME_DIR
#                   directory for per-issue outcome records
#                   (default: .agents/state/outcomes)
#   AGENT_REQUIRE_READY
#                   when set to 1 (or pass --require-ready), run
#                   .agents/scripts/agent-issue-readiness on each issue first
#                   and skip the claude session (recording a "blocked"
#                   outcome) if it is not ready. Default is 0 (off): issues
#                   are dispatched as before.
#
# v1 is attended: it opens PRs but never merges. You review and merge yourself.
set -euo pipefail

AGENT_REPO_DIR="${AGENT_REPO_DIR:-$HOME/nix}"
BASE_BRANCH="${BASE_BRANCH:-main}"
REPO_URL="${REPO_URL:-https://github.com/FilipNowakowicz/nixos-config.git}"
AGENT_OUTCOME_DIR="${AGENT_OUTCOME_DIR:-.agents/state/outcomes}"
AGENT_REQUIRE_READY="${AGENT_REQUIRE_READY:-0}"
SESSION_LOCK="/run/agent/session.lock"

label=""
issues=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --label)
    label="${2:?--label needs a value}"
    shift 2
    ;;
  --require-ready)
    AGENT_REQUIRE_READY=1
    shift
    ;;
  -h | --help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  --)
    shift
    ;;
  -*)
    echo "agent-run-issue: unknown flag: $1" >&2
    exit 2
    ;;
  *)
    issues+=("$1")
    shift
    ;;
  esac
done

die() {
  echo "agent-run-issue: $*" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || die "claude CLI not found (Home Manager agent role)"
command -v gh >/dev/null 2>&1 || die "gh not found"
command -v git >/dev/null 2>&1 || die "git not found"

# Fail fast if the scoped PAT is not wired — otherwise the run would burn a
# session only to fail at clone/push/PR time.
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (provision the scoped PAT — hosts/gcp-agent/CLAUDE.md)"

# Bootstrap the clone on a fresh/reprovisioned host: nothing else creates
# AGENT_REPO_DIR, and the host is disposable, so this is the steady-state path.
if [[ -d $AGENT_REPO_DIR/.git ]]; then
  : # existing clone — proceed as today
elif [[ -e $AGENT_REPO_DIR ]]; then
  die "AGENT_REPO_DIR=$AGENT_REPO_DIR exists but is not a git clone (refusing to touch it)"
else
  echo "agent-run-issue: bootstrapping clone of $REPO_URL at $AGENT_REPO_DIR ..." >&2
  git clone "$REPO_URL" "$AGENT_REPO_DIR" ||
    die "clone of $REPO_URL failed (check the scoped PAT — hosts/gcp-agent/CLAUDE.md)"
fi

# Hold the session lock for the WHOLE run so the idle-shutdown timer never powers
# the box off mid-session during claude-free gaps (offloaded builds, git ops).
# Best-effort: if /run/agent is not writable, process detection still covers the
# common case.
if (: >"$SESSION_LOCK") 2>/dev/null; then
  # shellcheck disable=SC2064
  trap "rm -f '$SESSION_LOCK'" EXIT
fi

cd "$AGENT_REPO_DIR"

utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

sync_base() {
  echo "agent-run-issue: syncing $BASE_BRANCH with origin ..." >&2
  git fetch origin --prune
  git checkout "$BASE_BRANCH"
  git reset --hard "origin/$BASE_BRANCH"
}

snapshot_learning_candidates() {
  local output="$1"
  if [[ -d .agents/learning/candidates ]]; then
    find .agents/learning/candidates -maxdepth 1 -type f \
      ! -name '.gitkeep' -printf '%p\n' | sort >"$output"
  else
    : >"$output"
  fi
}

new_learning_candidates() {
  local before="$1"
  local output="$2"
  local after
  after=$(mktemp)
  snapshot_learning_candidates "$after"
  comm -13 "$before" "$after" >"$output" || true
  rm -f "$after"
}

record_issue_outcome() {
  local issue="$1"
  local status="$2"
  local started_at="$3"
  local finished_at="$4"
  local exit_code="$5"
  local blocker="$6"
  local candidates_file="$7"
  local head_branch="$8"

  if [[ ! -x .agents/scripts/agent-record-outcome ]]; then
    echo "agent-run-issue: outcome recorder missing; skipped outcome record for issue #$issue" >&2
    return 0
  fi

  if outcome_path=$(
    .agents/scripts/agent-record-outcome \
      --issue "$issue" \
      --status "$status" \
      --base-branch "$BASE_BRANCH" \
      --repo-dir "$AGENT_REPO_DIR" \
      --started-at "$started_at" \
      --finished-at "$finished_at" \
      --exit-code "$exit_code" \
      --blocker "$blocker" \
      --learning-candidates-file "$candidates_file" \
      --head-branch "$head_branch" \
      --output-dir "$AGENT_OUTCOME_DIR"
  ); then
    echo "agent-run-issue: recorded outcome: $outcome_path" >&2
  else
    echo "agent-run-issue: failed to record outcome for issue #$issue" >&2
  fi
}

# Resolve the target issue list.
if [[ -n $label ]]; then
  mapfile -t issues < <(gh issue list --state open --label "$label" --json number --jq '.[].number')
  [[ ${#issues[@]} -gt 0 ]] || die "no open issues with label '$label'"
  echo "agent-run-issue: label '$label' -> issues: ${issues[*]}" >&2
fi
[[ ${#issues[@]} -gt 0 ]] || die "no target issue(s); pass an issue number or --label <name>"

run_one() {
  local issue="$1"
  echo "agent-run-issue: ===== issue #$issue =====" >&2
  local started_at finished_at status exit_code blocker before_candidates new_candidates outcome_head_branch
  started_at=$(utc_now)
  before_candidates=$(mktemp)
  new_candidates=$(mktemp)
  trap 'rm -f "$before_candidates" "$new_candidates"' RETURN

  if ! sync_base; then
    status=failure
    exit_code=1
    blocker="failed to sync ${BASE_BRANCH} from origin before issue session"
    : >"$new_candidates"
    finished_at=$(utc_now)
    record_issue_outcome "$issue" "$status" "$started_at" "$finished_at" "$exit_code" "$blocker" "$new_candidates" "$BASE_BRANCH"
    return "$exit_code"
  fi

  if [[ $AGENT_REQUIRE_READY == 1 ]]; then
    local readiness_output
    if ! readiness_output=$(.agents/scripts/agent-issue-readiness --issue "$issue" 2>&1); then
      status=blocked
      exit_code=1
      blocker="issue readiness lint failed: ${readiness_output}"
      : >"$new_candidates"
      finished_at=$(utc_now)
      record_issue_outcome "$issue" "$status" "$started_at" "$finished_at" "$exit_code" "$blocker" "$new_candidates" "$BASE_BRANCH"
      echo "agent-run-issue: issue #$issue is not ready; skipping (see outcome record)" >&2
      return "$exit_code"
    fi
  fi

  snapshot_learning_candidates "$before_candidates"

  # Hand the issue to Claude Code in headless mode, instructing it to follow the
  # repo's issue-driven-development skill end to end. Claude picks the branch,
  # implements the smallest durable fix, validates via the nix-verification-loop,
  # pushes, and opens a PR. It must NOT merge (attended v1).
  local prompt
  prompt="Implement GitHub issue #${issue} in this repository end to end using the \
issue-driven-development skill. Work on a new branch off ${BASE_BRANCH} (never commit \
to ${BASE_BRANCH} directly). Implement the smallest durable fix, validate with the \
nix-verification-loop skill (the smallest meaningful scripts/validate.sh command for \
what you changed), then push the branch and open a pull request that links the issue \
(use 'Closes #${issue}' only if the PR fully satisfies it, otherwise 'Refs #${issue}'). \
Do NOT merge the PR and do NOT push to ${BASE_BRANCH}. If you cannot complete it, stop \
and explain what is blocked."

  status=success
  exit_code=0
  blocker=""
  if claude -p "$prompt"; then
    echo "agent-run-issue: issue #$issue session finished" >&2
  else
    exit_code=$?
    status=failure
    blocker="claude session exited non-zero; inspect session output and linked PRs"
    echo "agent-run-issue: issue #$issue session exited non-zero — see output above; check 'gh pr list'" >&2
  fi

  finished_at=$(utc_now)
  outcome_head_branch=$(git symbolic-ref --short HEAD 2>/dev/null || printf 'DETACHED')
  new_learning_candidates "$before_candidates" "$new_candidates"
  record_issue_outcome "$issue" "$status" "$started_at" "$finished_at" "$exit_code" "$blocker" "$new_candidates" "$outcome_head_branch"
  return "$exit_code"
}

rc=0
for issue in "${issues[@]}"; do
  run_one "$issue" || rc=1
done

# Return to a clean base so the next cold start (or a human SSH) lands on
# ${BASE_BRANCH}; the idle-shutdown timer powers the box off after the window.
git checkout "$BASE_BRANCH" 2>/dev/null || true

echo "agent-run-issue: done. Open PRs:" >&2
gh pr list --state open --json number,title,headRefName \
  --jq '.[] | "  #\(.number) \(.headRefName): \(.title)"' >&2 || true
echo "agent-run-issue: review/merge from your workstation; the VM will self-power-off when idle." >&2
exit "$rc"
