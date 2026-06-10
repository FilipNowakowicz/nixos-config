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
#   scripts/agent-session.sh -- <cmd...>     # start, wait, run <cmd...> on host
#
# Env knobs (defaults match lib/hosts.nix + infra/variables.tf):
#   AGENT_NAME (gcp-agent)  AGENT_ZONE (europe-west2-a)
#   AGENT_FQDN (gcp-agent.tail90fc7a.ts.net)  SSH_USER (user)
#
# Prerequisite: gcloud authenticated with the agent's project active
#   (gcloud config set project <id>), and tailnet access as tag:workstation.
set -euo pipefail

AGENT_NAME="${AGENT_NAME:-gcp-agent}"
AGENT_ZONE="${AGENT_ZONE:-europe-west2-a}"
AGENT_FQDN="${AGENT_FQDN:-gcp-agent.tail90fc7a.ts.net}"
SSH_USER="${SSH_USER:-user}"

wait_only=0
remote_cmd=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --wait-only)
    wait_only=1
    shift
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

command -v gcloud >/dev/null 2>&1 || {
  echo "agent-session: gcloud not found (authenticate + set the agent project)" >&2
  exit 1
}
command -v ssh >/dev/null 2>&1 || {
  echo "agent-session: ssh not found" >&2
  exit 1
}

echo "agent-session: starting $AGENT_NAME (no-op if already running) ..." >&2
if ! gcloud compute instances start "$AGENT_NAME" --zone "$AGENT_ZONE" --quiet >/dev/null 2>&1; then
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

if [[ $wait_only == 1 ]]; then
  exit 0
fi

if [[ ${#remote_cmd[@]} -gt 0 ]]; then
  exec ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$AGENT_FQDN" -- "${remote_cmd[@]}"
fi

exec ssh -t -o StrictHostKeyChecking=accept-new "$SSH_USER@$AGENT_FQDN"
