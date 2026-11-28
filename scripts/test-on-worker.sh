#!/usr/bin/env bash
# on-worker drives the VM through scripts/lib/builder.sh. Assemble it the way
# home/profiles/on-worker.nix does and run it against a fake cloud and SSH.
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
export CLOUD="$test_dir/cloud"

{
  printf '#!%s\nset -euo pipefail\n' "$(command -v bash)"
  cat "$repo_root/scripts/lib/builder.sh"
  printf '%s\n' 'builder_fqdn=builder.example' 'builder_user="jobs"' 'builder_ssh_tries=60' 'NOTIFY_TOKEN_FILE='
  cat "$repo_root/home/files/scripts/on-worker.sh"
} >"$test_dir/bin/on-worker"

cat >"$test_dir/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CLOUD.log"
zone="" args=("$@")
for ((i = 0; i < $#; i++)); do [[ ${args[i]} != --zone ]] || zone=${args[i + 1]}; done
case "$2 $3" in
  "instances describe") [[ $4 == gcp-builder && $zone == "$(cat "$CLOUD.vm" 2>/dev/null)" ]] ;;
  "instances list") [[ -e $CLOUD.running ]] && echo RUNNING || echo TERMINATED ;;
  "instances start")
    if [[ -s $CLOUD.quota ]]; then
      left=$(cat "$CLOUD.quota")
      ((left > 0)) && {
        printf '%s' $((left - 1)) >"$CLOUD.quota"
        echo "Quota 'CPUS_ALL_REGIONS' exceeded. Limit: 16.0 globally."
        exit 1
      }
    fi
    touch "$CLOUD.running"
    ;;
  "instances stop") rm -f "$CLOUD.running" ;;
  "instances create")
    [[ $4 != gcp-builder ]] || {
      printf '%s' "$zone" >"$CLOUD.vm"
      touch "$CLOUD.running"
    }
    ;;
  "instances delete") : ;;
  "disks create") : ;;
  "snapshots describe")
    [[ -e $CLOUD.snap ]] || exit 1
    echo 2020-01-01T00:00:00Z
    ;;
  "snapshots delete") rm -f "$CLOUD.snap" ;;
  *) exit 99 ;;
esac
STUB
# Records each login and answers only while the VM runs.
cat >"$test_dir/bin/ssh" <<'STUB'
#!/usr/bin/env bash
while [[ $1 == -o || $1 == -i || $1 == -t ]]; do
  [[ $1 == -t ]] && shift || shift 2
done
printf '%s\n' "$1" >>"$CLOUD.ssh"
[[ -e $CLOUD.running ]] || exit 255
shift
[[ $# == 0 || $* == true ]]
STUB
printf '#!/usr/bin/env bash\n' >"$test_dir/bin/sleep"
sed -i "1c#!$(command -v bash)" "$test_dir/bin/gcloud" "$test_dir/bin/ssh" "$test_dir/bin/sleep"
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
export XDG_RUNTIME_DIR="$test_dir/run"
unset BUILDER_ZONE BUILDER_FQDN BUILDER_USER ON_WORKER_QUOTA_WAIT

reset_cloud() {
  rm -f "$CLOUD".*
  [[ -z ${1:-} ]] || printf '%s' "$1" >"$CLOUD.vm"
}

# status on a powered-off VM answers without starting it.
reset_cloud europe-west2-b
on-worker status 2>/dev/null
if grep -q 'instances start' "$CLOUD.log"; then
  echo 'status started a powered-off VM' >&2
  exit 1
fi

# start finds the VM's zone, starts it there and logs in as jobs only.
reset_cloud europe-west2-b
on-worker start 2>/dev/null
grep -qx 'compute instances start gcp-builder --zone europe-west2-b --quiet' "$CLOUD.log"
[[ $(sort -u "$CLOUD.ssh") == jobs@builder.example ]]

# A CPU quota refusal is waited out by default (1800 s), not fatal.
reset_cloud europe-west2-a
printf 2 >"$CLOUD.quota"
on-worker start 2>/dev/null
[[ $(grep -c 'instances start' "$CLOUD.log") == 3 ]]

# A move that died partway (no VM, old snapshot) is resumed, not "cannot find".
reset_cloud
touch "$CLOUD.snap"
on-worker start 2>/dev/null
[[ $(cat "$CLOUD.vm") == europe-west2-a && ! -e $CLOUD.snap ]]

# down powers the VM off in whatever zone it is in.
reset_cloud europe-west2-c
touch "$CLOUD.running"
on-worker down -f
grep -qx 'compute instances stop gcp-builder --zone europe-west2-c --quiet' "$CLOUD.log"
[[ ! -e $CLOUD.running ]]
echo 'on-worker builder tests passed'
