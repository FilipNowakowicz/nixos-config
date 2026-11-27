#!/usr/bin/env bash
# builder_spec reads gcp-builder's address, login and remoteBuilder spec from
# lib/hosts.nix in one evaluation; env overrides win and a failed read is loud.
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
export NIX_LOG="$test_dir/nix.log"
cat >"$test_dir/bin/nix" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NIX_LOG"
[[ ${NIX_RC:-0} == 0 ]] || exit 1
printf 'gcp-builder.example builduser x86_64-linux 14 2 nixos-test,kvm'
STUB
sed -i "1c#!$(command -v bash)" "$test_dir/bin/nix"
chmod +x "$test_dir/bin/nix"
export PATH="$test_dir/bin:$PATH"
unset BUILDER_FQDN BUILDER_USER BUILDER_MAXJOBS
export BUILDER_SSH_KEY=/keys/build

spec() (
  cd /
  # shellcheck source=scripts/lib/builder.sh disable=SC1091
  source "$script_dir/lib/builder.sh"
  builder_spec
)

[[ $(spec) == 'ssh-ng://builduser@gcp-builder.example x86_64-linux /keys/build 14 2 nixos-test,kvm' ]]
# One evaluation, of the registry file beside the library, from any directory.
[[ $(wc -l <"$NIX_LOG") == 1 ]]
grep -q -- "eval --raw --file $repo_root/lib/hosts.nix gcp-builder --apply" "$NIX_LOG"

[[ $(BUILDER_MAXJOBS=8 BUILDER_FQDN=100.64.0.1 BUILDER_USER=ci spec) == 'ssh-ng://ci@100.64.0.1 x86_64-linux /keys/build 8 2 nixos-test,kvm' ]]

if NIX_RC=1 spec 2>/dev/null; then
  echo 'builder_spec succeeded without the registry' >&2
  exit 1
fi
echo 'builder spec tests passed'
