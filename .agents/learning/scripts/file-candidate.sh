#!/usr/bin/env bash
# File one learning candidate into the inbox, after validating it.
#
# usage: file-candidate.sh FILE.yml   (or the YAML on stdin)
#
# The inbox is outside git (see common.sh), so filing never leaves untracked
# files in a shared checkout. An existing candidate with the same id is
# replaced, which is how a recurring lesson gets updated in place.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$script_dir/common.sh"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
src=${1:--}
if [[ $src == - ]]; then cat >"$stage/in.yml"; else cp -- "$src" "$stage/in.yml"; fi

id=$(sed -n 's/^id:[[:space:]]*//p' "$stage/in.yml" | head -1 | tr -d "\"'")
[[ $id =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+$ ]] || {
  echo "file-candidate: id must look like YYYY-MM-DD-kebab-slug, got '$id'" >&2
  exit 1
}
mkdir -p "$stage/check"
mv "$stage/in.yml" "$stage/check/$id.yml"
bash "$script_dir/validate-candidates.sh" "$stage/check"

inbox=$(learning_inbox)
mkdir -p "$inbox"
mv "$stage/check/$id.yml" "$inbox/$id.yml"
printf '%s\n' "$inbox/$id.yml"
