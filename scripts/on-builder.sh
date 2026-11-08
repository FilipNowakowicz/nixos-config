#!/usr/bin/env bash
# shellcheck disable=SC2029,SC2154
# Run a command on gcp-builder against a copy of this checkout, so evaluation,
# builds and VM tests all use the builder's CPU and memory instead of this one.
#
#   bash scripts/on-builder.sh nix build .#packages.x86_64-linux.foo --no-link
#   bash scripts/on-builder.sh true     # just start the VM
#
# The copy has the files Git tracks, with their current contents, the same set a
# dirty Git flake evaluates. Each run gets its own directory, so runs from several
# worktrees do not interfere. Build results stay on the builder.
set -euo pipefail

CDPATH='' cd -- "$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/lib/builder.sh disable=SC1091
source scripts/lib/builder.sh

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 2
fi

if [[ ${BUILDER_READY:-0} == 1 ]]; then
  resolve_builder_fqdn
else
  start_builder
fi

mapfile -t ssh_opts < <(builder_ssh_opts)
target="user@$builder_fqdn"
run_dir="work/run-$(date +%s)-$$"

# Runs interrupted by a lost connection cannot clean up after themselves.
ssh "${ssh_opts[@]}" "$target" \
  "mkdir -p '$run_dir' && find work -mindepth 1 -maxdepth 1 -name 'run-*' -mmin +1440 -exec rm -rf {} +"

git ls-files -z --cached |
  rsync -a --from0 --files-from=- --ignore-missing-args \
    -e "ssh ${ssh_opts[*]}" ./ "$target:$run_dir/"

printf -v remote_command '%q ' "$@"
ssh "${ssh_opts[@]}" "$target" \
  "cd '$run_dir' && ON_BUILDER=1 $remote_command; rc=\$?; cd && rm -rf '$run_dir'; exit \$rc"
