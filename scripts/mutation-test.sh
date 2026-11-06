#!/usr/bin/env bash
# Mutation test the repo's fast checks. See tests/mutation/PROTOCOL.md.
#
# Applies each mutant from tests/mutation/mutants.txt to the working tree, runs
# the covered check stages, records whether any stage failed, and restores the
# tree. Mutants are source edits only: nothing is deployed, no secret is read.
#
# Usage:
#   scripts/mutation-test.sh --baseline        # unmutated tree must pass all stages
#   scripts/mutation-test.sh [--out FILE] [--no-extra] [ID...]
#
# The working tree must be clean (tracked files) because it is reset with
# `git checkout -- .` after every mutant. Run it in a dedicated worktree.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

mode=mutate
out=""
run_extra=1
ids=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --baseline) mode=baseline ;;
  --out)
    out="$2"
    shift
    ;;
  --no-extra) run_extra=0 ;;
  -h | --help)
    sed -n '2,13p' "$0"
    exit 0
    ;;
  M*) ids+=("$1") ;;
  *)
    echo "unknown argument: $1" >&2
    exit 2
    ;;
  esac
  shift
done

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "error: tracked files are modified; commit or stash first (the runner resets the tree)" >&2
  exit 2
fi

system="$(nix eval --raw --impure --expr builtins.currentSystem)"
work="$(mktemp -d)"
nix_opts=(--option warn-dirty false --max-jobs 2 --cores 2)

restore() { git checkout -q -- .; }
cleanup() {
  restore
  rm -rf "$work"
}
trap cleanup EXIT

# Checks built by the `light` lane, read from validate.sh so the runner follows
# the repo's own gate. deploy-activate/deploy-schema are whole host closures;
# their evaluation is covered by the eval stage instead of a build.
light_attrs() {
  awk '/^light\)/{f=1} f&&/^  ;;/{exit} f' scripts/validate.sh |
    grep -o "checks\.\${system}\.[A-Za-z0-9_-]*" |
    sed 's/.*\.//' |
    grep -vx -e deploy-activate -e deploy-schema
}

# Checks that exist but are in no gate and are not whole-closure builds.
extra_attrs() {
  nix eval --json ".#checks.${system}" --apply builtins.attrNames 2>/dev/null |
    tr -d '[]"' | tr ',' '\n' |
    grep -vxF -f <(
      light_attrs
      printf '%s\n' deploy-activate deploy-schema pre-commit
    )
}

# Each stage prints a one-line detail on failure and returns non-zero.
stage_scripts() {
  local failed=()
  for s in scan-plaintext-secrets check-secrets-directory; do
    bash "scripts/${s}.sh" >"$work/${s}.log" 2>&1 || failed+=("${s}.sh")
  done
  ((${#failed[@]} == 0)) && return 0
  echo "${failed[*]}"
  return 1
}

stage_eval() {
  local log="$work/eval.log"
  : >"$log"
  # Chain with && explicitly: errexit is disabled inside a function that is
  # called from an `if`, so a failing earlier command would otherwise be lost.
  {
    nix "${nix_opts[@]}" eval --json ".#checks.${system}" \
      --apply 'c: builtins.mapAttrs (_: v: v.drvPath) c' >/dev/null &&
      nix "${nix_opts[@]}" eval --raw \
        ".#nixosConfigurations.main.config.system.build.toplevel.drvPath" >/dev/null &&
      nix "${nix_opts[@]}" eval --raw ".#packages.${system}.tailscale-acl.drvPath" >/dev/null
  } >"$log" 2>&1 && return 0
  summarize_eval_error "$log"
  return 1
}

summarize_eval_error() {
  grep -E "^error:|Failed assertions|^- |attribute '.*' (missing|in selection)|syntax error|undefined variable|Invariant|assert" "$1" |
    grep -v "^evaluation warning" | head -n 4 | tr '\n' ' ' | cut -c1-300
}

# Build attrs; report failing derivation names, or the eval error.
build_checks() {
  local log="$work/build.log" attrs=() a
  for a in "$@"; do attrs+=(".#checks.${system}.${a}"); done
  nix "${nix_opts[@]}" build --no-link --keep-going "${attrs[@]}" >"$log" 2>&1 && return 0
  local drvs
  drvs="$(grep -oE "Cannot build '[^']+'" "$log" | sed -E "s#.*/[a-z0-9]{32}-##; s#\.drv'##" | sort -u | tr '\n' ' ')"
  if [[ -n $drvs ]]; then
    echo "$drvs"
  else
    summarize_eval_error "$log"
  fi
  return 1
}

stage_light() {
  mapfile -t attrs < <(light_attrs)
  build_checks "${attrs[@]}"
}

stage_extra() {
  mapfile -t attrs < <(extra_attrs)
  build_checks "${attrs[@]}"
}

# Run stages in order; sets $stage and $detail for the first failure.
run_stages() {
  stage=""
  detail=""
  local name
  for name in scripts eval light extra; do
    [[ $name == extra && $run_extra -eq 0 ]] && continue
    if ! detail="$(stage_"$name")"; then
      stage="$name"
      return 1
    fi
  done
  detail=""
  return 0
}

if [[ $mode == baseline ]]; then
  if run_stages; then
    echo "baseline: all stages pass (scripts, eval, light$([[ $run_extra -eq 1 ]] && echo ', extra'))"
    exit 0
  fi
  echo "baseline FAILED at stage '$stage': $detail" >&2
  exit 1
fi

mapfile -t rows < <(python3 -I tests/mutation/apply.py list)
[[ -n $out ]] && printf 'id\tarea\texpected_layer\toutcome\tstage\tdetail\n' >"$out"

caught_gated=0 caught_extra=0 survived=0 excluded=0 total=0
for row in "${rows[@]}"; do
  IFS=$'\t' read -r id area layer _expected _summary <<<"$row"
  if ((${#ids[@]})) && [[ " ${ids[*]} " != *" $id "* ]]; then continue; fi
  total=$((total + 1))
  python3 -I tests/mutation/apply.py apply "$id"
  if run_stages; then
    outcome=SURVIVED
    survived=$((survived + 1))
  elif [[ $detail == *"syntax error"* || $detail == *"undefined variable"* ]]; then
    # Candidate exclusion: reviewed by hand against the PROTOCOL rule.
    outcome=EXCLUDED-REVIEW
    excluded=$((excluded + 1))
  elif [[ $stage == extra ]]; then
    outcome=CAUGHT-ungated
    caught_extra=$((caught_extra + 1))
  else
    outcome=CAUGHT
    caught_gated=$((caught_gated + 1))
  fi
  restore
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$area" "$layer" "$outcome" "${stage:--}" "${detail:--}" |
    tee -a "${out:-/dev/null}" >&2
done

echo "mutants=$total caught_gated=$caught_gated caught_ungated_only=$caught_extra survived=$survived excluded_review=$excluded"
