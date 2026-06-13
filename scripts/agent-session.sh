#!/usr/bin/env bash
# Start the on-demand gcp-agent VM and wait until it is reachable over Tailscale.
#
# gcp-agent is normally powered off and powers itself back off when idle (see
# the agent-idle-shutdown timer in hosts/gcp-agent/default.nix). This helper is
# the "start" side of that lifecycle — the agent analog of validate.sh's
# build-offload-focused ensure_builder, kept separate because its job is to open
# an interactive/orchestration session rather than to offload a build.
#
# Usage:
#   scripts/agent-session.sh                 # start, wait, open interactive SSH
#   scripts/agent-session.sh --wait-only     # start + confirm SSH, then exit 0
#   scripts/agent-session.sh --preflight-only
#                                            # start + confirm SSH, gh, and claude
#   scripts/agent-session.sh --issues <n|--label x>...
#                                            # start, wait, run the issue loop:
#                                            # ships the workstation's copy of
#                                            # agent-run-issue.sh to the host, so
#                                            # it works on a fresh host with no
#                                            # repo clone yet (the script then
#                                            # bootstraps the clone itself)
#   scripts/agent-session.sh -- <cmd...>     # start, wait, run <cmd...> on host
#   scripts/agent-session.sh --self-test     # offline regression test (stubbed
#                                            # gcloud/ssh/scp; proves artifacts
#                                            # are collected even when the
#                                            # remote issue run exits non-zero)
#
# Env knobs (defaults match lib/hosts.nix + infra/variables.tf):
#   AGENT_NAME (gcp-agent)  AGENT_ZONE (europe-west2-a)
#   AGENT_FQDN (gcp-agent.tail90fc7a.ts.net)  SSH_USER (user)
#   REMOTE_AGENT_REPO_DIR (nix)  relative or absolute repo path on gcp-agent
#
# Prerequisite: gcloud authenticated with the agent's project active
#   (gcloud config set project <id>), and tailnet access as tag:workstation.
#   If gcloud is not on PATH but nix is available, this script falls back to
#   `nix shell nixpkgs#google-cloud-sdk -c gcloud`.
set -euo pipefail

AGENT_NAME="${AGENT_NAME:-gcp-agent}"
AGENT_ZONE="${AGENT_ZONE:-europe-west2-a}"
AGENT_FQDN="${AGENT_FQDN:-gcp-agent.tail90fc7a.ts.net}"
SSH_USER="${SSH_USER:-user}"
REMOTE_AGENT_REPO_DIR="${REMOTE_AGENT_REPO_DIR:-nix}"

wait_only=0
preflight_only=0
remote_cmd=()
issue_args=()
run_issues=0
run_self_test=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --wait-only)
    wait_only=1
    shift
    ;;
  --preflight-only)
    preflight_only=1
    shift
    ;;
  --self-test)
    run_self_test=1
    shift
    ;;
  --issues)
    run_issues=1
    shift
    issue_args=("$@")
    break
    ;;
  --)
    shift
    remote_cmd=("$@")
    break
    ;;
  -h | --help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "agent-session: unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

collect_remote_dir_files() {
  local remote_dir="$1"
  local local_dir="$2"
  local name_glob="$3"
  local skip_existing="$4"
  local remote_dir_q
  remote_dir_q=$(printf '%q' "$remote_dir")

  mapfile -t remote_files < <(
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      "$SSH_USER@$AGENT_FQDN" \
      "find $remote_dir_q -maxdepth 1 -type f -name '$name_glob' -printf '%f\n' 2>/dev/null" ||
      true
  )

  [[ ${#remote_files[@]} -gt 0 ]] || return 0
  mkdir -p "$local_dir"

  local base remote_path
  for base in "${remote_files[@]}"; do
    [[ -n $base ]] || continue
    if [[ $skip_existing == 1 && -e $local_dir/$base ]]; then
      continue
    fi
    remote_path="${remote_dir%/}/$base"
    scp -q -o StrictHostKeyChecking=accept-new \
      "$SSH_USER@$AGENT_FQDN:$remote_path" "$local_dir/$base" ||
      echo "agent-session: failed to collect $remote_path" >&2
  done
}

collect_issue_artifacts() {
  echo "agent-session: collecting remote outcome records, session logs, and learning candidates ..." >&2
  collect_remote_dir_files \
    "$REMOTE_AGENT_REPO_DIR/.agents/state/outcomes" \
    ".agents/state/outcomes" \
    '*.json' \
    0
  collect_remote_dir_files \
    "$REMOTE_AGENT_REPO_DIR/.agents/state/sessions" \
    ".agents/state/sessions" \
    '*.log' \
    1
  collect_remote_dir_files \
    "$REMOTE_AGENT_REPO_DIR/.agents/learning/candidates" \
    ".agents/learning/candidates" \
    '*.yml' \
    1
}

preflight_issue_auth() {
  echo "agent-session: preflighting issue-run credentials on $AGENT_NAME ..." >&2

  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "$SSH_USER@$AGENT_FQDN" \
    "gh auth status >/dev/null" 2>/dev/null; then
    echo "agent-session: gh auth failed on $AGENT_NAME (check hosts/gcp-agent/secrets/gh-hosts.yaml)" >&2
    exit 1
  fi

  local remote_probe
  remote_probe=$(
    cat <<'EOF'
out=$(mktemp /tmp/agent-claude-preflight.XXXXXX)
rc=0
claude -p "say ok" --model sonnet --dangerously-skip-permissions >"$out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] &&
  grep -Eiq '(^|[^[:alpha:]])ok([^[:alpha:]]|$)' "$out" &&
  ! grep -Eiq '401|Invalid authentication credentials|Failed to authenticate|OAuth|quota|rate limit' "$out"; then
  rm -f "$out"
  exit 0
fi
tail -5 "$out" >&2 || true
rm -f "$out"
if [ "$rc" -eq 0 ]; then
  exit 1
fi
exit "$rc"
EOF
  )

  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "$SSH_USER@$AGENT_FQDN" "$remote_probe"; then
    echo "agent-session: claude auth/preflight failed on $AGENT_NAME" >&2
    echo "agent-session: refresh hosts/gcp-agent/secrets/claude-credentials.enc from a working login and activate/reprovision the host" >&2
    exit 1
  fi

  echo "agent-session: issue-run credentials ready" >&2
}

# Regression test for the artifact-collection path (learning candidate
# 2026-06-12-agent-session-collects-failed-outcomes): a NONZERO remote
# issue-run must still collect outcome records, session logs, and learning
# candidates before this script returns the remote exit code — failure
# records are most valuable exactly when the run failed. Everything external
# (gcloud/ssh/scp) is stubbed via PATH; no VM, network, or model is touched.
self_test() {
  local tmp bin work script_path rc
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  bin="$tmp/bin"
  work="$tmp/work"
  mkdir -p "$bin" "$work"
  script_path="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  fail() {
    echo "agent-session: self-test: $*" >&2
    exit 1
  }

  cat >"$bin/gcloud" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$bin/ssh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*agent-run-issue*)
  cat >/dev/null # consume the shipped runner script
  exit 7         # simulate a failed remote issue run
  ;;
*"find "*)
  case "$*" in
  *'*.json'*) printf 'stub-outcome.json\n' ;;
  *'*.log'*) printf 'stub-session.log\n' ;;
  *'*.yml'*) printf 'stub-candidate.yml\n' ;;
  esac
  exit 0
  ;;
*)
  exit 0 # reachability probe and anything else
  ;;
esac
EOF

  cat >"$bin/scp" <<'EOF'
#!/usr/bin/env bash
# Last argument is the local destination path.
args=("$@")
printf 'collected\n' >"${args[-1]}"
EOF
  chmod +x "$bin/gcloud" "$bin/ssh" "$bin/scp"

  rc=0
  (cd "$work" && PATH="$bin:$PATH" "$script_path" --issues 999 >/dev/null 2>&1) || rc=$?

  [[ $rc -eq 7 ]] ||
    fail "expected the remote exit code 7 to be preserved (got $rc)"
  [[ -f $work/.agents/state/outcomes/stub-outcome.json ]] ||
    fail "outcome record was not collected after a failed remote run"
  [[ -f $work/.agents/state/sessions/stub-session.log ]] ||
    fail "session log was not collected after a failed remote run"
  [[ -f $work/.agents/learning/candidates/stub-candidate.yml ]] ||
    fail "learning candidate was not collected after a failed remote run"

  printf 'agent-session self-test passed\n'
}

if [[ $run_self_test == 1 ]]; then
  self_test
  exit 0
fi

gcloud_cmd=(gcloud)
if ! command -v gcloud >/dev/null 2>&1; then
  if command -v nix >/dev/null 2>&1; then
    gcloud_cmd=(nix shell nixpkgs#google-cloud-sdk -c gcloud)
    echo "agent-session: gcloud not on PATH; using nixpkgs#google-cloud-sdk" >&2
  else
    echo "agent-session: gcloud not found and nix is unavailable (authenticate + set the agent project)" >&2
    exit 1
  fi
fi
command -v ssh >/dev/null 2>&1 || {
  echo "agent-session: ssh not found" >&2
  exit 1
}
command -v scp >/dev/null 2>&1 || {
  echo "agent-session: scp not found" >&2
  exit 1
}

echo "agent-session: starting $AGENT_NAME (no-op if already running) ..." >&2
if ! "${gcloud_cmd[@]}" compute instances start "$AGENT_NAME" --zone "$AGENT_ZONE" --quiet >/dev/null 2>&1; then
  echo "agent-session: could not start VM (check gcloud project/auth)" >&2
  exit 1
fi

echo "agent-session: waiting for SSH over Tailscale at $AGENT_FQDN ..." >&2
ready=0
for _ in $(seq 1 60); do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "$SSH_USER@$AGENT_FQDN" true 2>/dev/null; then
    ready=1
    break
  fi
  sleep 3
done

if [[ $ready != 1 ]]; then
  echo "agent-session: $AGENT_NAME not reachable over Tailscale after wait" >&2
  echo "agent-session: confirm it joined the tailnet (tailscale status | grep $AGENT_NAME)" >&2
  exit 1
fi

echo "agent-session: $AGENT_NAME ready" >&2

if [[ $preflight_only == 1 ]]; then
  preflight_issue_auth
  exit 0
fi

if [[ $wait_only == 1 ]]; then
  exit 0
fi

if [[ $run_issues == 1 ]]; then
  [[ ${#issue_args[@]} -gt 0 ]] || {
    echo "agent-session: --issues needs at least one issue number or --label <name>" >&2
    exit 2
  }
  preflight_issue_auth
  # Ship the workstation's copy of the entrypoint instead of invoking
  # nix/scripts/agent-run-issue.sh on the host: on a fresh/reprovisioned host
  # the clone does not exist yet, so the on-host path would fail before the
  # entrypoint's own clone bootstrap could run. `cat > tmpfile` (rather than
  # `bash -s`) so nothing in the script can swallow its own source from stdin;
  # the mktemp template keeps the remote cmdline matching the idle-shutdown
  # timer's `pgrep -f agent-run-issue` activity check.
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  printf -v issue_args_q ' %q' "${issue_args[@]}"
  set +e
  ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$AGENT_FQDN" -- \
    "tmp=\$(mktemp /tmp/agent-run-issue.XXXXXX) && cat >\"\$tmp\" && trap 'rm -f \"\$tmp\"' EXIT && bash \"\$tmp\"$issue_args_q" \
    <"$script_dir/agent-run-issue.sh"
  rc=$?
  set -e
  collect_issue_artifacts
  exit "$rc"
fi

if [[ ${#remote_cmd[@]} -gt 0 ]]; then
  exec ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$AGENT_FQDN" -- "${remote_cmd[@]}"
fi

exec ssh -t -o StrictHostKeyChecking=accept-new "$SSH_USER@$AGENT_FQDN"
