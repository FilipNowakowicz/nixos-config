#!/usr/bin/env bash
# Issue-loop orchestration entrypoint — runs ON gcp-agent.
#
# Given a target issue number (or a label filter), it drives the
# issue-driven-development skill from a cold, up-to-date clone through to a
# pushed PR, then returns and lets the idle-shutdown timer power the box off.
#
# Typical invocation from a workstation (starts the VM, then runs this on it):
#   scripts/agent-session.sh -- nix/scripts/agent-run-issue.sh 169
#   scripts/agent-session.sh -- nix/scripts/agent-run-issue.sh --label agent:ready
#
# Or directly, once SSH'd into gcp-agent:
#   scripts/agent-run-issue.sh 169 170
#   scripts/agent-run-issue.sh --label architecture-review
#
# `agent:ready` is the maintainer-owned default queue label for automated
# dispatch (see ".agents/README.md" "Dispatch Eligibility" and
# ".agents/scripts/agent-dispatchable-issues"). --label takes any label
# verbatim, so other queues (e.g. architecture-review) remain usable for
# attended runs.
#
# Env knobs:
#   AGENT_REPO_DIR  repo clone to operate in (default: $HOME/nix)
#   BASE_BRANCH     branch to sync to before each issue (default: main)
#   REPO_URL        HTTPS clone URL used to bootstrap AGENT_REPO_DIR when it
#                    does not exist yet (default: this repo, via gh's PAT)
#                    GitHub SSH push URLs are normalized back to HTTPS after
#                    clone setup: the agent host authenticates over HTTPS via
#                    gh's credential helper and has no GitHub SSH key, so an
#                    SSH push URL fails only at PR publication time, after a
#                    whole session has been spent (dogfood run 2026-06-12).
#                    Authenticated access to origin is preflighted before any
#                    session starts.
#   AGENT_OUTCOME_DIR
#                   directory for per-issue outcome records
#                   (default: .agents/state/outcomes)
#   AGENT_SESSION_DIR
#                   directory for per-issue inner-session logs. Each claude
#                   session runs with --output-format stream-json --verbose
#                   and its full event stream is written to
#                   <dir>/<started-at>-issue-<n>.log; the final "result"
#                   event supplies cost/turns/duration telemetry for the
#                   outcome record. (default: .agents/state/sessions)
#   AGENT_REQUIRE_READY
#                   when set to 1 (the default), run
#                   .agents/scripts/agent-issue-readiness on each issue first
#                   and skip the claude session (recording a "blocked"
#                   outcome) if it is not ready. Under-specified issues are the
#                   main source of sessions that explore for the full timeout
#                   and produce nothing, so the gate is on by default. Set to 0
#                   (or pass --no-require-ready) for an attended run on a
#                   known-good issue that lacks the formal section headings.
#   AGENT_CLAUDE_CMD
#                   Claude command to execute (default: claude). Tests can
#                   point this at a local fixture worker.
#   AGENT_INNER_TIMEOUT_SECONDS
#                   max seconds for one inner Claude issue session before it
#                   is terminated and recorded as a timeout failure
#                   (default: 900; 0 disables).
#   AGENT_HEARTBEAT_SECONDS
#                   seconds between cheap progress heartbeats while the inner
#                   session is alive (default: 60; 0 disables).
#   AGENT_INNER_KILL_GRACE_SECONDS
#                   seconds to wait after TERM before KILL (default: 15).
#   AGENT_ISSUE_COMMENTS
#                   when 1, post start/finish breadcrumbs to each GitHub issue
#                   for live operator visibility (default: 1; set 0 to disable).
#
# v1 is attended: it opens PRs but never merges. You review and merge yourself.
set -euo pipefail

AGENT_REPO_DIR="${AGENT_REPO_DIR:-$HOME/nix}"
BASE_BRANCH="${BASE_BRANCH:-main}"
REPO_URL="${REPO_URL:-https://github.com/FilipNowakowicz/nixos-config.git}"
AGENT_OUTCOME_DIR="${AGENT_OUTCOME_DIR:-.agents/state/outcomes}"
AGENT_SESSION_DIR="${AGENT_SESSION_DIR:-.agents/state/sessions}"
AGENT_REQUIRE_READY="${AGENT_REQUIRE_READY:-1}"
AGENT_CLAUDE_CMD="${AGENT_CLAUDE_CMD:-claude}"
AGENT_INNER_TIMEOUT_SECONDS="${AGENT_INNER_TIMEOUT_SECONDS:-900}"
AGENT_HEARTBEAT_SECONDS="${AGENT_HEARTBEAT_SECONDS:-60}"
AGENT_INNER_KILL_GRACE_SECONDS="${AGENT_INNER_KILL_GRACE_SECONDS:-15}"
AGENT_ISSUE_COMMENTS="${AGENT_ISSUE_COMMENTS:-1}"
SESSION_LOCK="/run/agent/session.lock"

label=""
issues=()
self_test=0
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
  --no-require-ready)
    AGENT_REQUIRE_READY=0
    shift
    ;;
  --self-test)
    self_test=1
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

validate_non_negative_integer() {
  local name="$1"
  local value="$2"
  [[ $value =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer (got: $value)"
}

validate_supervision_config() {
  validate_non_negative_integer AGENT_INNER_TIMEOUT_SECONDS "$AGENT_INNER_TIMEOUT_SECONDS"
  validate_non_negative_integer AGENT_HEARTBEAT_SECONDS "$AGENT_HEARTBEAT_SECONDS"
  validate_non_negative_integer AGENT_INNER_KILL_GRACE_SECONDS "$AGENT_INNER_KILL_GRACE_SECONDS"
}

github_ssh_to_https_url() {
  local url="$1"
  if [[ $url =~ ^git@github\.com:([^/]+)/(.+)$ ]] ||
    [[ $url =~ ^ssh://git@github\.com/([^/]+)/(.+)$ ]]; then
    printf 'https://github.com/%s/%s.git\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
    return 0
  fi
  return 1
}

ensure_push_safe_origin() {
  # The agent host pushes over HTTPS via gh's credential helper (scoped PAT)
  # and has no GitHub SSH key, so a GitHub SSH push URL fails with
  # "Permission denied (publickey)" only at PR publication time — after a
  # whole session has been spent. Normalize GitHub SSH push URLs back to
  # HTTPS; HTTPS and non-GitHub URLs are left unchanged.
  local repo_dir="$1"
  local push_url https_url
  push_url=$(git -C "$repo_dir" remote get-url --push origin 2>/dev/null || true)
  [[ -n $push_url ]] || return 0

  if https_url=$(github_ssh_to_https_url "$push_url"); then
    if [[ $push_url != "$https_url" ]]; then
      git -C "$repo_dir" remote set-url --push origin "$https_url"
      echo "agent-run-issue: normalized origin push URL to HTTPS (gh credential helper)" >&2
    fi
  fi
}

preflight_push_auth() {
  # Prove non-interactive authenticated access to origin BEFORE burning a
  # session: the 2026-06-11/12 dogfood runs each completed implementation and
  # failed only at `git push` (first a missing credential helper, then a
  # wrong SSH push URL). ls-remote exercises the same URL + credential path
  # the final push will use.
  local repo_dir="$1"
  GIT_TERMINAL_PROMPT=0 git -C "$repo_dir" ls-remote --heads origin >/dev/null 2>&1 ||
    die "cannot authenticate to origin non-interactively (check the scoped PAT / gh credential helper — hosts/gcp-agent/CLAUDE.md)"
}

heartbeat_worktree_summary() {
  local branch dirty
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || printf 'DETACHED')
  dirty=$(git status --short 2>/dev/null | wc -l | tr -d ' ')
  printf 'branch=%s dirty=%s' "$branch" "$dirty"
}

terminate_inner_session() {
  local pid="$1"
  local kill_target="$2"
  local grace="$3"
  local waited=0

  kill -TERM -- "$kill_target" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $(ps -o stat= -p "$pid" 2>/dev/null || true) == Z* ]]; then
      break
    fi
    if ((waited >= grace)); then
      kill -KILL -- "$kill_target" 2>/dev/null || true
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

supervise_inner_session() {
  local issue="$1"
  local session_log="$2"
  shift 2
  validate_supervision_config

  local start now elapsed next_heartbeat pid kill_target rc log_bytes
  start=$(date +%s)
  next_heartbeat=$((start + AGENT_HEARTBEAT_SECONDS))

  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$session_log" 2>&1 &
    pid=$!
    kill_target="-$pid"
  else
    "$@" >"$session_log" 2>&1 &
    pid=$!
    kill_target="$pid"
  fi

  echo "agent-run-issue: issue #$issue inner session started pid=$pid timeout=${AGENT_INNER_TIMEOUT_SECONDS}s heartbeat=${AGENT_HEARTBEAT_SECONDS}s log=$session_log" >&2

  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    elapsed=$((now - start))

    if ((AGENT_INNER_TIMEOUT_SECONDS > 0 && elapsed >= AGENT_INNER_TIMEOUT_SECONDS)); then
      echo "agent-run-issue: issue #$issue inner session exceeded timeout after ${elapsed}s; terminating pid=$pid" >&2
      terminate_inner_session "$pid" "$kill_target" "$AGENT_INNER_KILL_GRACE_SECONDS"
      set +e
      wait "$pid" 2>/dev/null
      set -e
      return 124
    fi

    if ((AGENT_HEARTBEAT_SECONDS > 0 && now >= next_heartbeat)); then
      log_bytes=$(wc -c <"$session_log" 2>/dev/null | tr -d ' ' || printf '0')
      echo "agent-run-issue: issue #$issue heartbeat elapsed=${elapsed}s log_bytes=${log_bytes:-0} $(heartbeat_worktree_summary)" >&2
      next_heartbeat=$((now + AGENT_HEARTBEAT_SECONDS))
    fi

    sleep 1
  done

  set +e
  wait "$pid"
  rc=$?
  set -e
  return "$rc"
}

# Print the last stream-json "result" event from a session log (claude -p
# --output-format stream-json), or "null" when the log has none — e.g. the
# CLI died before emitting any event. Never fails the caller.
parse_session_result() {
  local log="$1"
  if [[ ! -s $log ]]; then
    printf 'null\n'
    return 0
  fi
  jq -cRs '
    split("\n")
    | map(fromjson? // empty)
    | map(select(type == "object" and .type == "result"))
    | (last // null)' "$log" 2>/dev/null || printf 'null\n'
}

linked_pr_count() {
  local issue="$1"
  local head_branch="$2"
  {
    if [[ -n $head_branch && $head_branch != DETACHED ]]; then
      gh pr list --state all --head "$head_branch" --json number 2>/dev/null || true
    fi
    gh pr list --state all --search "#${issue} in:body" --json number,body 2>/dev/null |
      jq -c --arg issue "$issue" '
        map(select((.body // "")
          | test("(?i)(close[sd]?|fix(es|ed)?|resolve[sd]?|refs?)[[:space:]]+#" + $issue + "\\b")))
        | map(del(.body))' 2>/dev/null || true
  } | jq -rs '
    (add // [])
    | map(select(type == "object" and (.number | type == "number")))
    | unique_by(.number)
    | length
  ' 2>/dev/null || printf '0\n'
}

has_clean_pr_after_timeout() {
  local issue="$1"
  local head_branch="$2"
  local dirty_count pr_count

  [[ -n $head_branch && $head_branch != "$BASE_BRANCH" && $head_branch != DETACHED ]] || return 1
  dirty_count=$(git status --short 2>/dev/null | wc -l | tr -d ' ' || printf '1')
  [[ ${dirty_count:-1} == 0 ]] || return 1
  pr_count=$(linked_pr_count "$issue" "$head_branch")
  [[ ${pr_count:-0} =~ ^[0-9]+$ && ${pr_count:-0} -gt 0 ]]
}

self_test() {
  local tmp repo bin out rc old_timeout old_heartbeat old_grace
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  repo="$tmp/repo"
  bin="$tmp/bin"

  mkdir -p "$repo" "$bin"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name 'Agent Runner Test'
  printf 'seed\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m seed
  git -C "$repo" remote add origin git@github.com:example-owner/example-repo.git
  ensure_push_safe_origin "$repo"
  [[ $(git -C "$repo" remote get-url --push origin) == https://github.com/example-owner/example-repo.git ]] ||
    die "self-test: expected GitHub SSH origin push URL to convert to HTTPS"

  git -C "$repo" remote set-url origin https://github.com/example-owner/example-repo.git
  git -C "$repo" remote set-url --push origin https://github.com/example-owner/example-repo.git
  ensure_push_safe_origin "$repo"
  [[ $(git -C "$repo" remote get-url --push origin) == https://github.com/example-owner/example-repo.git ]] ||
    die "self-test: expected existing HTTPS push URL to be preserved"

  git -C "$repo" remote set-url --push origin ssh://git@github.com/example-owner/example-repo.git
  ensure_push_safe_origin "$repo"
  [[ $(git -C "$repo" remote get-url --push origin) == https://github.com/example-owner/example-repo.git ]] ||
    die "self-test: expected ssh:// GitHub push URL to convert to HTTPS"

  git -C "$repo" remote set-url origin git@gitlab.example.invalid:example-owner/example-repo.git
  git -C "$repo" remote set-url --push origin git@gitlab.example.invalid:example-owner/example-repo.git
  ensure_push_safe_origin "$repo"
  [[ $(git -C "$repo" remote get-url --push origin) == git@gitlab.example.invalid:example-owner/example-repo.git ]] ||
    die "self-test: expected non-GitHub SSH push URL to be preserved"

  cat >"$bin/success-worker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'success-worker received %s args\n' "$#"
EOF
  chmod +x "$bin/success-worker"

  cat >"$bin/slow-worker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'exit 143' TERM
sleep 30
EOF
  chmod +x "$bin/slow-worker"

  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == pr && ${2:-} == list ]]; then
  case "$*" in
  *"--head codex/clean-pr"*) printf '[{"number":77}]\n' ;;
  *"#999 in:body"*) printf '[{"number":77,"body":"Refs #999"}]\n' ;;
  *) printf '[]\n' ;;
  esac
  exit 0
fi
exit 1
EOF
  chmod +x "$bin/gh"
  PATH="$bin:$PATH"

  old_timeout="$AGENT_INNER_TIMEOUT_SECONDS"
  old_heartbeat="$AGENT_HEARTBEAT_SECONDS"
  old_grace="$AGENT_INNER_KILL_GRACE_SECONDS"

  cd "$repo"
  git checkout -q -b codex/clean-pr
  has_clean_pr_after_timeout 999 codex/clean-pr ||
    die "self-test: expected clean linked PR to classify as post-PR timeout"
  printf 'dirty\n' >dirty.txt
  if has_clean_pr_after_timeout 999 codex/clean-pr; then
    die "self-test: dirty worktree must not classify as post-PR timeout"
  fi
  rm -f dirty.txt

  AGENT_INNER_TIMEOUT_SECONDS=10
  AGENT_HEARTBEAT_SECONDS=1
  AGENT_INNER_KILL_GRACE_SECONDS=1
  set +e
  out=$(supervise_inner_session 999 "$tmp/success.log" "$bin/success-worker" -p prompt 2>&1)
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || die "self-test: expected success worker rc 0 (got $rc; output: $out)"
  [[ $out == *"inner session started"* ]] || die "self-test: missing start line (output: $out)"
  grep -q 'success-worker received' "$tmp/success.log" ||
    die "self-test: worker output not captured in session log"

  printf '%s\n' '{"type":"system","subtype":"init"}' \
    '{"type":"result","subtype":"success","total_cost_usd":0.42,"num_turns":7,"duration_ms":12345,"session_id":"abc-123"}' \
    >"$tmp/result.log"
  out=$(parse_session_result "$tmp/result.log")
  [[ $(jq -r '.total_cost_usd' <<<"$out") == 0.42 ]] ||
    die "self-test: expected parse_session_result to find the result event (got: $out)"
  printf 'not json at all\n' >"$tmp/noise.log"
  [[ $(parse_session_result "$tmp/noise.log") == null ]] ||
    die "self-test: expected null result for a log without result events"
  [[ $(parse_session_result "$tmp/missing.log") == null ]] ||
    die "self-test: expected null result for a missing log"

  AGENT_INNER_TIMEOUT_SECONDS=2
  AGENT_HEARTBEAT_SECONDS=1
  AGENT_INNER_KILL_GRACE_SECONDS=1
  set +e
  out=$(supervise_inner_session 999 "$tmp/slow.log" "$bin/slow-worker" 2>&1)
  rc=$?
  set -e
  [[ $rc -eq 124 ]] || die "self-test: expected timeout rc 124 (got $rc; output: $out)"
  [[ $out == *"heartbeat elapsed="* ]] || die "self-test: missing heartbeat line (output: $out)"
  [[ $out == *"exceeded timeout"* ]] || die "self-test: missing timeout line (output: $out)"

  AGENT_INNER_TIMEOUT_SECONDS="$old_timeout"
  AGENT_HEARTBEAT_SECONDS="$old_heartbeat"
  AGENT_INNER_KILL_GRACE_SECONDS="$old_grace"
  printf 'agent-run-issue self-test passed\n'
}

if [[ $self_test == 1 ]]; then
  self_test
  exit 0
fi

command -v "$AGENT_CLAUDE_CMD" >/dev/null 2>&1 || die "$AGENT_CLAUDE_CMD CLI not found (Home Manager agent role)"
command -v gh >/dev/null 2>&1 || die "gh not found"
command -v git >/dev/null 2>&1 || die "git not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

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
ensure_push_safe_origin "$AGENT_REPO_DIR"
preflight_push_auth "$AGENT_REPO_DIR"

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

post_issue_comment() {
  local issue="$1"
  local body="$2"
  [[ $AGENT_ISSUE_COMMENTS == 1 ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0

  local tmp
  tmp=$(mktemp)
  printf '%s\n' "$body" >"$tmp"
  if gh issue comment "$issue" --body-file "$tmp" >/dev/null 2>&1; then
    echo "agent-run-issue: posted issue #$issue observability comment" >&2
  else
    echo "agent-run-issue: failed to post issue #$issue observability comment" >&2
  fi
  rm -f "$tmp"
}

discover_pr_lines() {
  local issue="$1"
  local head_branch="$2"
  {
    if [[ -n $head_branch && $head_branch != DETACHED ]]; then
      gh pr list --state all --head "$head_branch" --json number,title,state,url 2>/dev/null || true
    fi
    # The body search alone is too loose: any PR merely quoting "#<issue>"
    # matches (dogfood run 2026-06-12 attached an unrelated PR to two
    # outcomes). Keep only PRs whose body links the issue with a
    # closing/reference keyword.
    gh pr list --state all --search "#${issue} in:body" --json number,title,state,url,body 2>/dev/null |
      jq -c --arg issue "$issue" '
        map(select((.body // "")
          | test("(?i)(close[sd]?|fix(es|ed)?|resolve[sd]?|refs?)[[:space:]]+#" + $issue + "\\b")))
        | map(del(.body))' 2>/dev/null || true
  } | jq -rs '
    (add // [])
    | map(select(type == "object" and (.number | type == "number")))
    | unique_by(.number)
    | sort_by(.number)
    | if length == 0 then
        "- (none found yet)"
      else
        map("- #\(.number) \(.state): \(.title) (\(.url))") | join("\n")
      end
  ' 2>/dev/null || printf '%s\n' '- (failed to query PRs)'
}

post_started_comment() {
  local issue="$1"
  local started_at="$2"
  post_issue_comment "$issue" "$(
    cat <<EOF
### Agent run started

- started_at: ${started_at}
- base_branch: ${BASE_BRANCH}
- runner: gcp-agent issue loop
- mode: attended; opens PRs, never merges

The runner will post a finish comment with status, blocker, branch, and linked PRs.
EOF
  )"
}

post_finished_comment() {
  local issue="$1"
  local status="$2"
  local exit_code="$3"
  local started_at="$4"
  local finished_at="$5"
  local head_branch="$6"
  local blocker="$7"
  local outcome_path="$8"
  local session_log="${9:-}"
  local session_cost="${10:-}"
  local session_turns="${11:-}"

  local blocker_text pr_lines outcome_text
  blocker_text="${blocker:-"(none)"}"
  outcome_text="${outcome_path:-"(not recorded)"}"
  pr_lines=$(discover_pr_lines "$issue" "$head_branch")

  post_issue_comment "$issue" "$(
    cat <<EOF
### Agent run finished

- status: ${status}
- exit_code: ${exit_code}
- started_at: ${started_at}
- finished_at: ${finished_at}
- head_branch: ${head_branch}
- blocker: ${blocker_text}
- outcome_record: ${outcome_text}
- session_log: ${session_log:-"(none)"}
- cost_usd: ${session_cost:-"(unknown)"}
- turns: ${session_turns:-"(unknown)"}

Linked PRs:
${pr_lines}
EOF
  )"
}

LAST_OUTCOME_PATH=""

record_issue_outcome() {
  local issue="$1"
  local status="$2"
  local started_at="$3"
  local finished_at="$4"
  local exit_code="$5"
  local blocker="$6"
  local candidates_file="$7"
  local head_branch="$8"
  local route_file="${9:-}"
  local session_log="${10:-}"
  local session_cost="${11:-}"
  local session_turns="${12:-}"
  local session_duration_ms="${13:-}"
  local session_id="${14:-}"

  LAST_OUTCOME_PATH=""
  if [[ ! -x .agents/scripts/agent-record-outcome ]]; then
    echo "agent-run-issue: outcome recorder missing; skipped outcome record for issue #$issue" >&2
    return 0
  fi

  local route_args=()
  if [[ -n $route_file && -s $route_file ]]; then
    route_args=(--route-file "$route_file")
  fi

  local session_args=()
  [[ -n $session_log ]] && session_args+=(--session-log "$session_log")
  [[ -n $session_cost ]] && session_args+=(--session-cost-usd "$session_cost")
  [[ -n $session_turns ]] && session_args+=(--session-turns "$session_turns")
  [[ -n $session_duration_ms ]] && session_args+=(--session-duration-ms "$session_duration_ms")
  [[ -n $session_id ]] && session_args+=(--session-id "$session_id")

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
      --output-dir "$AGENT_OUTCOME_DIR" \
      "${route_args[@]}" \
      "${session_args[@]}"
  ); then
    LAST_OUTCOME_PATH="$outcome_path"
    echo "agent-run-issue: recorded outcome: $outcome_path" >&2
  else
    echo "agent-run-issue: failed to record outcome for issue #$issue" >&2
  fi
}

# Compute an advisory route decision for paths changed relative to
# $BASE_BRANCH and write it as JSON to $output (best-effort; never fails the
# caller). Leaves $output empty if agent-route is missing or errors.
compute_route_decision() {
  local output="$1"
  : >"$output"
  if [[ -x .agents/scripts/agent-route ]]; then
    .agents/scripts/agent-route --git-diff "$BASE_BRANCH" --json >"$output" 2>/dev/null || : >"$output"
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
  local started_at finished_at status exit_code blocker before_candidates new_candidates outcome_head_branch route_file
  local session_log session_result session_cost session_turns session_duration_ms session_id
  started_at=$(utc_now)
  post_started_comment "$issue" "$started_at"
  before_candidates=$(mktemp)
  new_candidates=$(mktemp)
  route_file=$(mktemp)
  trap 'rm -f "$before_candidates" "$new_candidates" "$route_file"' RETURN

  mkdir -p "$AGENT_SESSION_DIR"
  session_log="$AGENT_SESSION_DIR/$(printf '%s' "$started_at" | tr -c '0-9TZ:-' '-')-issue-${issue}.log"
  session_cost="" session_turns="" session_duration_ms="" session_id=""

  if ! sync_base; then
    status=failure
    exit_code=1
    blocker="failed to sync ${BASE_BRANCH} from origin before issue session"
    : >"$new_candidates"
    finished_at=$(utc_now)
    record_issue_outcome "$issue" "$status" "$started_at" "$finished_at" "$exit_code" "$blocker" "$new_candidates" "$BASE_BRANCH"
    post_finished_comment "$issue" "$status" "$exit_code" "$started_at" "$finished_at" "$BASE_BRANCH" "$blocker" "$LAST_OUTCOME_PATH"
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
      post_finished_comment "$issue" "$status" "$exit_code" "$started_at" "$finished_at" "$BASE_BRANCH" "$blocker" "$LAST_OUTCOME_PATH"
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
to ${BASE_BRANCH} directly). When the relevant files are not already obvious, use the \
repo-map-query skill to locate them instead of broad cat/grep/find sweeps, then open \
only the top likely files. Implement the smallest durable fix, validate with the \
nix-verification-loop skill (the smallest meaningful scripts/validate.sh command for \
what you changed), then push the branch and open a pull request that links the issue \
(use 'Closes #${issue}' only if the PR fully satisfies it, otherwise 'Refs #${issue}'). \
Do NOT merge the PR, do NOT push to ${BASE_BRANCH}, and do NOT wait for long GitHub \
Actions checks after the PR is open; treat CI as asynchronous unless a required check \
has already failed and needs an immediate fix. If you cannot complete it, stop and \
explain what is blocked."

  status=success
  exit_code=0
  blocker=""
  if supervise_inner_session "$issue" "$session_log" \
    "$AGENT_CLAUDE_CMD" -p "$prompt" --output-format stream-json --verbose; then
    echo "agent-run-issue: issue #$issue session finished" >&2
  else
    exit_code=$?
    status=failure
    if [[ $exit_code -eq 124 ]]; then
      blocker="claude session exceeded AGENT_INNER_TIMEOUT_SECONDS=${AGENT_INNER_TIMEOUT_SECONDS}; inspect $session_log and git status"
      echo "agent-run-issue: issue #$issue session timed out — see $session_log; check 'git status' and 'gh pr list'" >&2
    else
      blocker="claude session exited non-zero; inspect $session_log and linked PRs"
      echo "agent-run-issue: issue #$issue session exited non-zero — see $session_log; check 'gh pr list'" >&2
    fi
    echo "agent-run-issue: last session output for issue #$issue:" >&2
    tail -n 40 "$session_log" >&2 2>/dev/null || true

    if [[ $exit_code -eq 124 ]]; then
      outcome_head_branch=$(git symbolic-ref --short HEAD 2>/dev/null || printf 'DETACHED')
      if has_clean_pr_after_timeout "$issue" "$outcome_head_branch"; then
        status=success
        exit_code=0
        blocker="claude session timed out after a clean linked PR was already opened; treating as post-PR finalization timeout"
        echo "agent-run-issue: issue #$issue timeout happened after linked PR publication; recording success with blocker note" >&2
      fi
    fi
  fi

  session_result=$(parse_session_result "$session_log")
  session_cost=$(jq -r '.total_cost_usd // empty' <<<"$session_result" 2>/dev/null || true)
  session_turns=$(jq -r '.num_turns // empty' <<<"$session_result" 2>/dev/null || true)
  session_duration_ms=$(jq -r '.duration_ms // empty' <<<"$session_result" 2>/dev/null || true)
  session_id=$(jq -r '.session_id // empty' <<<"$session_result" 2>/dev/null || true)
  echo "agent-run-issue: issue #$issue session telemetry: cost_usd=${session_cost:-unknown} turns=${session_turns:-unknown} log=$session_log" >&2

  finished_at=$(utc_now)
  outcome_head_branch=$(git symbolic-ref --short HEAD 2>/dev/null || printf 'DETACHED')
  new_learning_candidates "$before_candidates" "$new_candidates"
  compute_route_decision "$route_file"
  record_issue_outcome "$issue" "$status" "$started_at" "$finished_at" "$exit_code" "$blocker" "$new_candidates" "$outcome_head_branch" "$route_file" \
    "$session_log" "$session_cost" "$session_turns" "$session_duration_ms" "$session_id"
  post_finished_comment "$issue" "$status" "$exit_code" "$started_at" "$finished_at" "$outcome_head_branch" "$blocker" "$LAST_OUTCOME_PATH" \
    "$session_log" "$session_cost" "$session_turns"
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
