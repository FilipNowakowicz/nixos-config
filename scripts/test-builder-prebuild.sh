#!/usr/bin/env bash
# No network, store writes or builds: all Nix operations are stubs.
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin"
export STATE_DIRECTORY="$fixture/state" PREBUILD_LOG="$fixture/log"
export TEST_REV=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export TEST_STORE=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-main-fixture
cat >"$fixture/bin/nix" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$PREBUILD_LOG"
case "$1" in
  flake) printf '{"locked":{"rev":"%s"}}\n' "$TEST_REV" ;;
  eval) echo /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-displaylink.zip ;;
  path-info) [[ ${MISSING_BLOB:-0} != 1 ]] ;;
  build)
    [[ ${FAIL_BUILD:-0} != 1 ]] || exit 42
    while [[ $1 != --out-link ]]; do shift; done
    ln -sfn "$TEST_STORE" "$2"
    ;;
  *) exit 99 ;;
esac
STUB
cat >"$fixture/bin/nix-store" <<'STUB'
#!/usr/bin/env bash
printf 'root %s\n' "$*" >>"$PREBUILD_LOG"
STUB
# The Nix sandbox has no /usr/bin/env.
for stub in "$fixture/bin/"*; do
  sed -i "1c#!$(command -v bash)" "$stub"
done
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"

# Missing requireFile must stop before a build, with actionable status.
if MISSING_BLOB=1 bash "$script_dir/builder-prebuild.sh"; then
  echo 'missing DisplayLink incorrectly succeeded' >&2
  exit 1
fi
jq -e --arg rev "$TEST_REV" '.result == "missing-displaylink" and .revision == $rev and (.error | contains("Seed privately"))' "$STATE_DIRECTORY/status.json" >/dev/null
SERVICE_RESULT=exit-code bash "$script_dir/builder-prebuild.sh" --service-failed
jq -e '.result == "missing-displaylink" and (.error | contains("Seed privately"))' "$STATE_DIRECTORY/status.json" >/dev/null
if grep -q '^build ' "$PREBUILD_LOG"; then
  echo 'attempted a build without the required source' >&2
  exit 1
fi

if FAIL_BUILD=1 bash "$script_dir/builder-prebuild.sh"; then
  echo 'failed build incorrectly succeeded' >&2
  exit 1
fi
jq -e '.result == "failed" and .store_path == ""' "$STATE_DIRECTORY/status.json" >/dev/null

bash "$script_dir/builder-prebuild.sh"
jq -e --arg rev "$TEST_REV" --arg path "$TEST_STORE" '.result == "success" and .revision == $rev and .store_path == $path and .error == "" and (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$STATE_DIRECTORY/status.json" >/dev/null
grep -q "^build github:FilipNowakowicz/nixos-config/$TEST_REV#nixosConfigurations.main.config.system.build.toplevel " "$PREBUILD_LOG"
grep -q '^root --add-root .*displaylink-source --indirect --realise ' "$PREBUILD_LOG"
[[ $(readlink "$STATE_DIRECTORY/system") == "$TEST_STORE" ]]

# Even an untrappable process kill must not leave a stale successful status.
SERVICE_RESULT=timeout bash "$script_dir/builder-prebuild.sh" --service-failed
jq -e --arg rev "$TEST_REV" '.result == "timeout" and .revision == $rev and .store_path == ""' "$STATE_DIRECTORY/status.json" >/dev/null
echo 'builder-prebuild tests passed'
