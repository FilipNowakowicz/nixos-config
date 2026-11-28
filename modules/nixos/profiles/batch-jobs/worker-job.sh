# shellcheck shell=bash
# Runs one on-worker job: worker-job <name> <command string>.
# The command runs through a login shell so it sees the system PATH and
# environment, writes to ~/jobs/<name>/log, and leaves its exit status in
# ~/jobs/<name>/exit.
name=$1
command=$2
dir="$HOME/jobs/$name"
mkdir -p "$dir"
rm -f "$dir/exit"
printf '%s\n' "$command" >"$dir/command"
printf '%s\n' "$PWD" >"$dir/workdir"
date +%s >"$dir/started"

# NOTIFY_URL and NOTIFY_TAGS come from the worker-job wrapper (default.nix);
# on-worker seeds the builder's publish-only token on every run.
notify() {
  local token_file="$HOME/.config/worker/ntfy-token"
  [[ -r $token_file ]] || return 0
  curl -fsS -m 10 \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$(<"$token_file")") \
    -H "Title: on-worker: $name" -H "Priority: $2" -H "Tags: $NOTIFY_TAGS" \
    -d "$1" "$NOTIFY_URL" >/dev/null 2>&1 || true
}

# systemd stops the unit with SIGTERM to the whole cgroup (on-worker stop, or
# RuntimeMaxSec). Let the command exit on it, then record the result.
trap ':' TERM

rc=0
bash -lc "$command" >>"$dir/log" 2>&1 || rc=$?
printf '%s\n' "$rc" >"$dir/exit"

minutes=$((($(date +%s) - $(<"$dir/started")) / 60))
if [[ $rc == 0 ]]; then
  notify "finished in ${minutes}m" default
else
  notify "failed with exit $rc after ${minutes}m" high
fi
exit "$rc"
