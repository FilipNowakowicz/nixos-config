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

notify() {
  local url_file="$HOME/.config/worker/notify-url"
  [[ -r $url_file ]] || return 0
  curl -fsS -m 10 -H "Title: gcp-worker: $name" -d "$1" "$(<"$url_file")" >/dev/null 2>&1 || true
}

# systemd stops the unit with SIGTERM to the whole cgroup (on-worker stop, or
# RuntimeMaxSec). Let the command exit on it, then record the result.
trap ':' TERM

rc=0
bash -lc "$command" >>"$dir/log" 2>&1 || rc=$?
printf '%s\n' "$rc" >"$dir/exit"

minutes=$((($(date +%s) - $(<"$dir/started")) / 60))
if [[ $rc == 0 ]]; then
  notify "finished in ${minutes}m"
else
  notify "failed with exit $rc after ${minutes}m"
fi
exit "$rc"
