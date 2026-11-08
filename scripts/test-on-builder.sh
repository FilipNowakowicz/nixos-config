#!/usr/bin/env bash
# Exercise transfer contents and remote-shell semantics without a cloud account.
set -euo pipefail
repo_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
REAL_RSYNC="$(command -v rsync)"
export REAL_RSYNC
export TEST_REMOTE_HOME="$test_dir/remote"
export TEST_EVENTS="$test_dir/events"
mkdir -p "$test_dir/repo/scripts/lib" "$test_dir/repo/infra" "$test_dir/bin" "$TEST_REMOTE_HOME"
cp "$repo_root/scripts/on-builder.sh" "$repo_root/scripts/validate.sh" "$test_dir/repo/scripts/"
cp "$repo_root/scripts/lib/builder.sh" "$test_dir/repo/scripts/lib/builder.sh"
export BUILDER_SSH_KEY="$test_dir/build-key"
touch "$test_dir/build-key"
cat >"$test_dir/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
printf 'gcloud\n' >> "$TEST_EVENTS"
exit "${TEST_GCLOUD_RC:-0}"
STUB
cat >"$test_dir/bin/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
while [[ ${1:-} == -o || ${1:-} == -i ]]; do shift 2; done
[[ $1 == user@builder.example ]]
shift
cd "$TEST_REMOTE_HOME"
HOME="$TEST_REMOTE_HOME" bash -c "$*"
STUB
cat >"$test_dir/bin/rsync" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# Preserve the real options and file-list stdin. Only replace the SSH destination
# with a local fake remote; real rsync decides which files actually get copied.
args=("$@")
last=$((${#args[@]} - 1))
[[ ${args[last]} == user@builder.example:* ]]
args[last]="$TEST_REMOTE_HOME/${args[last]#*:}"
"$REAL_RSYNC" "${args[@]}"
STUB
cat >"$test_dir/bin/nix" <<'STUB'
#!/usr/bin/env bash
printf 'local nix invoked\n' >&2
exit 37
STUB
chmod +x "$test_dir/bin/"*
# Nix sandboxes have no /usr/bin/env; use the Bash supplied by the check.
sed -i "1c#!$(command -v bash)" "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
export BUILDER_FQDN=builder.example
unset BUILDER_READY ON_BUILDER USE_BUILDER
cd "$test_dir/repo"
git init -q
git config user.name Test
git config user.email test@example.invalid
printf 'infra/terraform.tfvars\n' >.gitignore
printf 'do not transfer\n' >infra/terraform.tfvars
printf 'tracked before edit\n' >'tracked file'
cat >verify.sh <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail
[[ ${ON_BUILDER:-0} == 1 ]]
[[ ! -e infra/terraform.tfvars ]]
[[ $(cat 'tracked file') == 'tracked dirty contents' ]]
[[ $# == 3 && $1 == 'argument with spaces' && $2 == "quote's and \"quotes\"" && $3 == '$(must not execute)' ]]
printf 'remote verified\n' >> "$TEST_EVENTS"
exit 23
REMOTE
git add .
printf 'tracked dirty contents\n' >'tracked file'
rc=0
bash scripts/on-builder.sh bash verify.sh 'argument with spaces' "quote's and \"quotes\"" '$(must not execute)' || rc=$?
[[ $rc == 23 ]]
grep -Fxq 'gcloud' "$TEST_EVENTS"
grep -Fxq 'remote verified' "$TEST_EVENTS"
[[ -z $(find "$TEST_REMOTE_HOME/work" -mindepth 1 -maxdepth 1 -name 'run-*' -print) ]]

# Fail startup, then prove the warning occurs before validate invokes local nix.
# Nix is stubbed, so a regression cannot accidentally start a local build.
rc=0
TEST_GCLOUD_RC=1 bash scripts/validate.sh flake-eval >"$test_dir/fallback.log" 2>&1 || rc=$?
[[ $rc == 37 ]]
awk '
  /remote builder: UNAVAILABLE, running on this machine instead/ { warned = 1 }
  /local nix invoked/ { if (!warned) exit 1; invoked = 1 }
  END { if (!warned || !invoked) exit 1 }
' "$test_dir/fallback.log"
echo 'on-builder contract tests passed'
