# shellcheck shell=bash disable=SC2016,SC2029
# on-worker: run long CPU-heavy jobs from any Git checkout on the on-demand
# gcp-worker VM (hosts/gcp-worker). Installed by home/profiles/gcp-worker.nix,
# which sets WORKER_HOST, WORKER_VM and NOTIFY_URL_FILE above this text.
#
# Each checkout gets a persistent workspace on the worker, so .venv and caches
# survive between runs. Jobs run detached under the worker's `jobs` user and
# keep the VM up until they finish; it powers itself off 20 minutes after.

usage() {
  cat <<'EOF'
usage: on-worker <command> [args]

  run [options] [--] CMD...  Sync this checkout to the worker and start CMD there
      -n, --name NAME          job name (default: <repo>-<timestamp>)
      -i, --include PATH       also sync PATH (repeatable; e.g. gitignored data)
      -t, --max-runtime DUR    stop the job after DUR (systemd time, default 24h)
      -w, --wait               follow the log and exit with the job's status
  status                     List jobs and their state
  logs [-f] [NAME]           Show a job's log (default: the newest job)
  wait [NAME]                Follow a job until it ends; exit with its status
  stop NAME                  Stop a running job
  pull PATH...               Copy PATHs from this checkout's workspace back here
  sync [-i PATH]...          Only sync this checkout to its workspace
  ssh [CMD...]               Shell (or CMD) in this checkout's workspace
  start                      Start the VM and wait for SSH
  down [-f]                  Power the VM off (refuses while a job runs, unless -f)

CMD runs in a login shell from the checkout root, e.g.
  on-worker run -n calib -- uv run python scripts/calibrate.py --workers 14
Files synced: everything Git tracks plus untracked files that are not ignored.
EOF
}

die() {
  echo "on-worker: $*" >&2
  exit 1
}

control_dir="${XDG_RUNTIME_DIR:-/tmp}/on-worker"
mkdir -p "$control_dir"
chmod 700 "$control_dir"
ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ServerAliveInterval=30
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto
  -o "ControlPath=$control_dir/%C"
  -o ControlPersist=120
)
target="jobs@$WORKER_HOST"

remote() {
  ssh "${ssh_opts[@]}" "$target" "$@"
}

# Run a bash script on the worker with positional args.
remote_script() {
  local script=$1
  shift
  local args
  printf -v args '%q ' "$@"
  ssh "${ssh_opts[@]}" "$target" "bash -s -- $args" <<<"$script"
}

gcloud_cmd=()
resolve_gcloud() {
  if command -v gcloud >/dev/null 2>&1; then
    gcloud_cmd=(gcloud)
  else
    gcloud_cmd=(nix shell nixpkgs#google-cloud-sdk -c gcloud)
  fi
}

reachable() {
  ssh "${ssh_opts[@]}" -o ConnectTimeout=5 "$target" true 2>/dev/null
}

start_vm() {
  reachable && return 0
  resolve_gcloud
  local zone output deadline
  zone=$("${gcloud_cmd[@]}" compute instances list --filter="name=$WORKER_VM" \
    --format='value(zone.basename())' 2>/dev/null) || true
  [[ -n $zone ]] || die "cannot find the $WORKER_VM VM (check gcloud login and project)"
  deadline=$(($(date +%s) + ${ON_WORKER_QUOTA_WAIT:-1800}))
  echo "on-worker: starting $WORKER_VM ..." >&2
  until output=$("${gcloud_cmd[@]}" compute instances start "$WORKER_VM" --zone "$zone" --quiet 2>&1); do
    if [[ $output == *CPUS_ALL_REGIONS* ]] && (($(date +%s) < deadline)); then
      # The project CPU cap fits either the worker or gcp-builder, which
      # powers itself off after 20 idle minutes.
      echo "on-worker: no CPU quota free yet (gcp-builder is probably running); retrying in 60s" >&2
      sleep 60
      continue
    fi
    printf '%s\n' "$output" >&2
    die "could not start $WORKER_VM"
  done
  for _ in $(seq 1 60); do
    if reachable; then
      echo "on-worker: $WORKER_VM ready" >&2
      return 0
    fi
    sleep 3
  done
  die "$WORKER_VM started but is not reachable over SSH"
}

toplevel=""
workspace=""
resolve_checkout() {
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a Git checkout"
  local base hash
  base=$(basename "$toplevel" | tr -c 'A-Za-z0-9_.\n-' '-')
  hash=$(printf '%s' "$toplevel" | sha256sum | cut -c1-8)
  workspace="work/$base-$hash"
}

seed_notify_url() {
  [[ -n ${NOTIFY_URL_FILE:-} && -r $NOTIFY_URL_FILE ]] || return 0
  remote 'umask 077; mkdir -p ~/.config/worker; cat > ~/.config/worker/notify-url' <"$NOTIFY_URL_FILE" ||
    echo "on-worker: could not seed the ntfy topic; jobs will finish silently" >&2
}

sync_checkout() {
  local includes=("$@")
  remote "mkdir -p '$workspace'"
  (
    cd "$toplevel" || exit
    git ls-files -z --cached --others --exclude-standard |
      rsync -a --from0 --files-from=- --ignore-missing-args \
        -e "ssh ${ssh_opts[*]}" ./ "$target:$workspace/"
    if ((${#includes[@]} > 0)); then
      rsync -a --relative -e "ssh ${ssh_opts[*]}" -- "${includes[@]}" "$target:$workspace/"
    fi
  )
}

# Remote side of `status`: one line per job, newest first.
status_script='
cd ~/jobs 2>/dev/null || { echo "no jobs yet"; exit 0; }
printf "%-36s %-12s %-17s %s\n" JOB STATE STARTED COMMAND
for dir in $(ls -1t); do
  [[ -d $dir ]] || continue
  if systemctl --user is-active -q "worker-job-$dir" 2>/dev/null; then
    state=running
  elif [[ -f $dir/exit ]]; then
    rc=$(<"$dir/exit")
    if [[ $rc == 0 ]]; then state=done; else state="failed($rc)"; fi
  else
    state=lost
  fi
  started=$(date -d "@$(cat "$dir/started" 2>/dev/null || echo 0)" "+%Y-%m-%d %H:%M")
  printf "%-36s %-12s %-17s %s\n" "$dir" "$state" "$started" "$(head -c 80 "$dir/command" 2>/dev/null)"
done
'

# Remote side of `wait`: follow the log until the unit ends, then exit with
# the recorded status.
wait_script='
name=$1
dir=~/jobs/$name
[[ -d $dir ]] || { echo "on-worker: no job $name" >&2; exit 2; }
touch "$dir/log"
tail -n +1 -F "$dir/log" 2>/dev/null &
tail_pid=$!
while systemctl --user is-active -q "worker-job-$name" 2>/dev/null; do sleep 5; done
sleep 1
kill "$tail_pid" 2>/dev/null
rc=$(cat "$dir/exit" 2>/dev/null || echo 255)
echo "on-worker: job $name exited with status $rc" >&2
exit "$rc"
'

newest_job() {
  remote 'ls -1t ~/jobs 2>/dev/null | head -n1'
}

cmd_run() {
  local name="" max_runtime=24h wait=0 includes=()
  while (($# > 0)); do
    case $1 in
    -n | --name)
      name=$2
      shift 2
      ;;
    -i | --include)
      includes+=("$2")
      shift 2
      ;;
    -t | --max-runtime)
      max_runtime=$2
      shift 2
      ;;
    -w | --wait)
      wait=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*) die "unknown run option: $1" ;;
    *) break ;;
    esac
  done
  (($# > 0)) || die "run needs a command (on-worker run -- CMD...)"
  resolve_checkout
  [[ -n $name ]] || name="$(basename "$workspace" | sed 's/-[0-9a-f]\{8\}$//')-$(date +%Y%m%d-%H%M%S)"
  [[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || die "job name may only contain letters, digits, _ . -"

  start_vm
  seed_notify_url
  echo "on-worker: syncing $toplevel" >&2
  sync_checkout "${includes[@]}"

  local command
  printf -v command '%q ' "$@"
  remote_script '
name=$1 workspace=$2 max_runtime=$3 command=$4
if systemctl --user is-active -q "worker-job-$name" 2>/dev/null; then
  echo "on-worker: job $name is already running" >&2
  exit 1
fi
rm -rf ~/jobs/"$name"
systemd-run --user --quiet --collect --unit "worker-job-$name" \
  --working-directory "$HOME/$workspace" \
  -p RuntimeMaxSec="$max_runtime" -p KillMode=control-group -p TimeoutStopSec=30s \
  "$(command -v worker-job)" "$name" "$command"
' "$name" "$workspace" "$max_runtime" "$command"

  echo "on-worker: started job $name (max runtime $max_runtime)" >&2
  echo "  follow:  on-worker logs -f $name"
  echo "  results: on-worker pull <path>"
  if ((wait)); then
    remote_script "$wait_script" "$name"
  fi
}

cmd_logs() {
  local follow=0 name
  if [[ ${1:-} == -f ]]; then
    follow=1
    shift
  fi
  name=${1:-$(newest_job)}
  [[ -n $name ]] || die "no jobs yet"
  if ((follow)); then
    remote_script "$wait_script" "$name"
  else
    remote "cat ~/jobs/'$name'/log"
  fi
}

cmd_pull() {
  (($# > 0)) || die "pull needs at least one path"
  resolve_checkout
  local sources=() path
  for path in "$@"; do
    sources+=("$target:$workspace/./${path#./}")
  done
  (cd "$toplevel" && rsync -a --relative -e "ssh ${ssh_opts[*]}" -- "${sources[@]}" ./)
}

cmd_down() {
  local force=0
  [[ ${1:-} != -f ]] || force=1
  if reachable && ((! force)); then
    if remote 'systemctl --user list-units --state=active --no-legend "worker-job-*" | grep -q .'; then
      die "a job is still running (on-worker status); use down -f to power off anyway"
    fi
  fi
  resolve_gcloud
  local zone
  zone=$("${gcloud_cmd[@]}" compute instances list --filter="name=$WORKER_VM" --format='value(zone.basename())')
  "${gcloud_cmd[@]}" compute instances stop "$WORKER_VM" --zone "$zone" --quiet
}

sub=${1:-}
[[ -n $sub ]] || {
  usage
  exit 2
}
shift
case $sub in
run) cmd_run "$@" ;;
status)
  start_vm
  remote_script "$status_script"
  ;;
logs)
  start_vm
  cmd_logs "$@"
  ;;
wait)
  start_vm
  name=${1:-$(newest_job)}
  remote_script "$wait_script" "$name"
  ;;
stop)
  [[ -n ${1:-} ]] || die "stop needs a job name"
  start_vm
  remote "systemctl --user stop 'worker-job-$1'"
  ;;
pull)
  start_vm
  cmd_pull "$@"
  ;;
sync)
  includes=()
  while [[ ${1:-} == -i || ${1:-} == --include ]]; do
    includes+=("$2")
    shift 2
  done
  resolve_checkout
  start_vm
  sync_checkout "${includes[@]}"
  ;;
ssh)
  resolve_checkout
  start_vm
  if (($# > 0)); then
    printf -v cmd '%q ' "$@"
    ssh "${ssh_opts[@]}" "$target" "cd '$workspace' && bash -lc $(printf '%q' "$cmd")"
  else
    ssh "${ssh_opts[@]}" -t "$target" "cd '$workspace' 2>/dev/null; exec bash -l"
  fi
  ;;
start) start_vm ;;
down) cmd_down "$@" ;;
-h | --help | help) usage ;;
*)
  usage >&2
  exit 2
  ;;
esac
