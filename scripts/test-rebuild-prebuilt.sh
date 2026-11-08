#!/usr/bin/env bash
# Read-only local contract tests. Every external operation is stubbed; a real
# main closure is used only to check activation-executable existence on success.
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/repo/scripts/lib"
cp "$script_dir/rebuild-prebuilt.sh" "$work/repo/scripts/"
cp "$script_dir/lib/builder.sh" "$work/repo/scripts/lib/"
export TEST_REPO="$work/repo" TEST_LOG="$work/log" TEST_STATUS="$work/status"
export TEST_REV=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export BUILDER_FQDN=builder.example.test
export TEST_HOST=main TEST_COPY_FAIL=0 TEST_STATUS_FAIL=0 TEST_REF_FAIL=0
export PATH="$work/bin:$PATH"
cat >"$work/bin/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'rev-parse --show-toplevel') echo "$TEST_REPO" ;;
  'rev-parse --verify refs/remotes/origin/main^{commit}')
    [[ $TEST_REF_FAIL == 0 ]] || exit 1
    echo "$TEST_REV" ;;
  *) exit 90 ;;
esac
STUB
cat >"$work/bin/hostname" <<'STUB'
#!/usr/bin/env bash
echo "$TEST_HOST"
STUB
cat >"$work/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo start >> "$TEST_LOG"
STUB
cat >"$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[[ ${*: -1} == true ]] && exit 0
[[ $TEST_STATUS_FAIL == 0 ]] || exit 1
cat "$TEST_STATUS"
STUB
cat >"$work/bin/nix" <<'STUB'
#!/usr/bin/env bash
[[ $1 == copy && $2 == --from && $3 == ssh-ng://user@builder.example.test ]] || exit 91
[[ $4 == --no-check-sigs ]] || exit 91
echo copy >> "$TEST_LOG"
[[ $TEST_COPY_FAIL == 0 ]]
STUB
cat >"$work/bin/sudo" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == nix-env && $2 == -p && $3 == /nix/var/nix/profiles/system && $4 == --set ]]; then
  echo profile >> "$TEST_LOG"
elif [[ $1 == */bin/switch-to-configuration && $2 == switch ]]; then
  echo activate >> "$TEST_LOG"
else
  exit 92
fi
STUB
# The Nix sandbox has no /usr/bin/env.
for stub in "$work/bin/"*; do
  sed -i "1c#!$(command -v bash)" "$stub"
done
chmod +x "$work/bin/"*
valid_path=${TEST_SYSTEM_PATH:-$(readlink -f /run/current-system)}
status() {
  jq -n --arg result "$1" --arg revision "$2" --arg store_path "$3" \
    '{revision:$revision,store_path:$store_path,result:$result,timestamp:"2026-11-08T10:00:00Z",error:""}' >"$TEST_STATUS"
}
run_rejected() {
  : >"$TEST_LOG"
  if bash "$work/repo/scripts/rebuild-prebuilt.sh" "$@" >"$work/output" 2>&1; then
    echo "unexpected success" >&2
    exit 1
  fi
  if grep -Eq '^(profile|activate)$' "$TEST_LOG"; then
    echo "rejected input reached activation" >&2
    exit 1
  fi
}
for result in building failed missing-displaylink timeout; do
  status "$result" "$TEST_REV" "$valid_path"
  run_rejected
done
status success bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$valid_path"
run_rejected
status success "$TEST_REV" /nix/store/not-a-system
run_rejected
printf '{broken json' >"$TEST_STATUS"
run_rejected
status success "$TEST_REV" "$valid_path"
TEST_STATUS_FAIL=1 run_rejected
TEST_REF_FAIL=1 run_rejected
TEST_HOST=other run_rejected
run_rejected --remote
TEST_COPY_FAIL=1 run_rejected
# Exercise the successful ordering without invoking the installed closure.
if [[ $valid_path =~ ^/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-nixos-system-main-[A-Za-z0-9.+_-]+$ && -x $valid_path/bin/switch-to-configuration ]]; then
  : >"$TEST_LOG"
  bash "$work/repo/scripts/rebuild-prebuilt.sh" >"$work/output" 2>&1
  printf 'start\ncopy\nprofile\nactivate\n' >"$work/expected"
  diff -u "$work/expected" "$TEST_LOG"
else
  echo 'SKIP successful path: provide TEST_SYSTEM_PATH pointing at an existing main closure' >&2
fi
echo 'rebuild-prebuilt contract tests passed'
