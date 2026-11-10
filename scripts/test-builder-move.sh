#!/usr/bin/env bash
# A fake cloud: no network, and nothing real is created or deleted.
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
export CLOUD="$test_dir/cloud"
cat >"$test_dir/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CLOUD.log"
zone="" args=("$@")
for ((i = 0; i < $#; i++)); do [[ ${args[i]} != --zone ]] || zone=${args[i + 1]}; done
full() { [[ " ${FULL:-} " == *" $zone "* ]]; }
case "$2 $3" in
  "instances describe") [[ $4 == gcp-builder && $zone == "$(cat "$CLOUD.vm" 2>/dev/null)" ]] ;;
  "instances start")
    if full; then
      echo ZONE_RESOURCE_POOL_EXHAUSTED
      exit 1
    fi
    [[ ${START_RC:-0} == 0 ]]
    ;;
  "instances create")
    ! full || exit 1
    [[ $4 != gcp-builder ]] || printf '%s' "$zone" >"$CLOUD.vm"
    ;;
  "instances delete") [[ $4 != gcp-builder ]] || rm -f "$CLOUD.vm" ;;
  "disks snapshot")
    [[ ! -e $CLOUD.snap ]] || exit 1
    touch "$CLOUD.snap"
    ;;
  "disks create") : ;;
  "snapshots describe")
    [[ -e $CLOUD.snap ]] || exit 1
    echo "$SNAP_TIME"
    ;;
  "snapshots delete") rm -f "$CLOUD.snap" ;;
  *) exit 99 ;;
esac
STUB
cat >"$test_dir/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[[ ${SSH_RC:-0} == 0 ]]
STUB
printf '#!/usr/bin/env bash\n' >"$test_dir/bin/sleep"
sed -i "1c#!$(command -v bash)" "$test_dir/bin/"*
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
export BUILDER_FQDN=builder.example SNAP_TIME=2020-01-01T00:00:00Z
unset BUILDER_ZONE

run_start() (
  # shellcheck source=scripts/lib/builder.sh disable=SC1091
  source "$script_dir/lib/builder.sh"
  start_builder 2>/dev/null || return 1
  # shellcheck disable=SC2154 # builder_zone is set by the sourced lib/builder.sh
  [[ ${1:-} == "$builder_zone" ]]
)
reset_cloud() {
  rm -f "$CLOUD".*
  printf '%s' "$1" >"$CLOUD.vm"
}
line_of() { grep -n -m1 -- "$1" "$CLOUD.log" | cut -d: -f1; }

# A running zone needs no move, and the VM is found wherever it is.
reset_cloud europe-west2-c
run_start europe-west2-c
if grep -q 'snapshot' "$CLOUD.log"; then
  echo 'moved without a capacity failure' >&2
  exit 1
fi

# A full zone moves to the next one with room, in the safe order.
reset_cloud europe-west2-a
FULL=europe-west2-a run_start europe-west2-b
[[ $(cat "$CLOUD.vm") == europe-west2-b ]]
[[ ! -e $CLOUD.snap ]]
probe=$(line_of 'instances create gcp-builder-probe --zone europe-west2-b')
snap=$(line_of 'disks snapshot')
del=$(line_of 'instances delete gcp-builder --zone europe-west2-a')
new=$(line_of 'instances create gcp-builder --zone europe-west2-b')
((probe < snap && snap < del && del < new))

# It skips a second full zone.
reset_cloud europe-west2-a
FULL='europe-west2-a europe-west2-b' run_start europe-west2-c

# With nowhere to go, the VM is left exactly as it was.
reset_cloud europe-west2-a
if FULL='europe-west2-a europe-west2-b europe-west2-c' run_start; then
  echo 'succeeded with every zone full' >&2
  exit 1
fi
[[ $(cat "$CLOUD.vm") == europe-west2-a && ! -e $CLOUD.snap ]]

# Other start failures must not trigger a move.
reset_cloud europe-west2-a
if START_RC=1 run_start; then
  echo 'succeeded after a start failure' >&2
  exit 1
fi
[[ $(cat "$CLOUD.vm") == europe-west2-a && ! -e $CLOUD.snap ]]

# The snapshot stays if the new VM never answers.
reset_cloud europe-west2-a
if FULL=europe-west2-a SSH_RC=1 run_start; then
  echo 'succeeded without SSH' >&2
  exit 1
fi
[[ -e $CLOUD.snap ]]

# An interrupted move resumes from an old snapshot, but not a recent one.
rm -f "$CLOUD".*
touch "$CLOUD.snap"
run_start europe-west2-a
[[ $(cat "$CLOUD.vm") == europe-west2-a && ! -e $CLOUD.snap ]]
rm -f "$CLOUD".*
touch "$CLOUD.snap"
if SNAP_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ) run_start; then
  echo 'touched a move that may still be running' >&2
  exit 1
fi
[[ ! -e $CLOUD.vm ]]
echo 'builder zone-move tests passed'
