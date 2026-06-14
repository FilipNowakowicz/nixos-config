#!/usr/bin/env bash
# Scaffold a failing executable check for a promoted learning candidate.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scaffold-promotion-check.sh --candidate <path> --check-name <slug> [--validate-target docs|light] [--output-dir <repo>]
  scaffold-promotion-check.sh --self-test

Creates:
  .agents/learning/promotions/<slug>.sh

and wires it into scripts/validate.sh under the chosen validation target. The
generated check intentionally exits 1 with a TODO until the reviewer replaces
the body with the real assertion.
EOF
}

die() {
  echo "scaffold-promotion-check: $*" >&2
  exit 1
}

field() {
  local path="$1"
  local name="$2"
  sed -n "s/^${name}:[[:space:]]*//p" "$path" | head -1 |
    tr '\t' ' ' |
    sed "s/^\"//; s/\"$//; s/^'//; s/'$//"
}

slug_ok() {
  [[ $1 =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

insert_validate_wiring() {
  local validate_file="$1"
  local target="$2"
  local command_line="$3"

  [[ -f $validate_file ]] || die "missing validate script: $validate_file"
  grep -Fqx "$command_line" "$validate_file" && return 0
  grep -Fxq "${target})" "$validate_file" ||
    die "validate target '$target' not found in $validate_file"

  local tmp
  tmp=$(mktemp)
  awk -v target="${target})" -v command_line="$command_line" '
    {
      print
      if ($0 == target && inserted == 0) {
        print command_line
        inserted = 1
      }
    }
  ' "$validate_file" >"$tmp"
  mv "$tmp" "$validate_file"
}

scaffold() {
  local candidate="$1"
  local check_name="$2"
  local validate_target="$3"
  local output_dir="$4"

  [[ -f $candidate ]] || die "candidate not found: $candidate"
  slug_ok "$check_name" || die "--check-name must be a slug matching [a-z0-9][a-z0-9_-]*"
  case "$validate_target" in
  docs | light) ;;
  *) die "--validate-target must be docs or light" ;;
  esac

  local status route best_form id dedupe evidence candidate_ref promotions_dir check_path validate_file command_line
  status=$(field "$candidate" status)
  route=$(field "$candidate" route)
  best_form=$(field "$candidate" best_form)
  id=$(field "$candidate" id)
  dedupe=$(field "$candidate" dedupe_key)
  evidence=$(field "$candidate" evidence)

  [[ $status == promoted ]] || die "candidate status must be promoted (got: ${status:-missing})"
  [[ $route == implement-fix ]] || die "candidate route must be implement-fix (got: ${route:-missing})"
  case "$best_form" in
  test | assertion | invariant | check) ;;
  *) die "candidate best_form must be test/assertion/invariant/check (got: ${best_form:-missing})" ;;
  esac

  output_dir=${output_dir%/}
  promotions_dir="$output_dir/.agents/learning/promotions"
  check_path="$promotions_dir/${check_name}.sh"
  validate_file="$output_dir/scripts/validate.sh"
  candidate_ref="$candidate"
  if [[ $candidate == "$output_dir/"* ]]; then
    candidate_ref="${candidate#"$output_dir/"}"
  fi

  mkdir -p "$promotions_dir"
  [[ ! -e $check_path ]] || die "refusing to overwrite existing check: $check_path"

  cat >"$check_path" <<EOF
#!/usr/bin/env bash
# TODO: replace this scaffold with the executable assertion promoted from:
#   ${candidate_ref}
set -euo pipefail

cat >&2 <<'TODO'
TODO: implement promoted learning check.
candidate: ${candidate_ref}
id: ${id:-unknown}
dedupe_key: ${dedupe:-unknown}
evidence: ${evidence:-unknown}

Replace this body with an assertion that fails when the learned regression is
possible again, then keep this script wired into scripts/validate.sh.
TODO
exit 1
EOF
  chmod +x "$check_path"

  command_line="  bash .agents/learning/promotions/${check_name}.sh"
  insert_validate_wiring "$validate_file" "$validate_target" "$command_line"

  printf '%s\n' "$check_path"
}

self_test() {
  local tmp candidate out rc
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/.agents/learning/candidates/archive" "$tmp/scripts"
  cat >"$tmp/.agents/learning/candidates/archive/example.yml" <<'EOF'
schema: learning-candidate/v1
id: example-promoted-check
status: promoted
route: implement-fix
best_form: test
dedupe_key: example:check
evidence: [PR-#1]
EOF
  cat >"$tmp/scripts/validate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command="${1:-}"
case "$command" in
docs)
  echo docs-ok
  ;;
light)
  echo light-ok
  ;;
esac
EOF
  chmod +x "$tmp/scripts/validate.sh"

  candidate="$tmp/.agents/learning/candidates/archive/example.yml"
  out=$(scaffold "$candidate" "example-check" "docs" "$tmp")
  [[ $out == "$tmp/.agents/learning/promotions/example-check.sh" ]] ||
    die "self-test: unexpected scaffold path: $out"
  grep -Fqx '  bash .agents/learning/promotions/example-check.sh' "$tmp/scripts/validate.sh" ||
    die "self-test: validate.sh wiring was not inserted"
  grep -Fq 'candidate: .agents/learning/candidates/archive/example.yml' "$out" ||
    die "self-test: generated check missing candidate back-reference"

  set +e
  (cd "$tmp" && bash scripts/validate.sh docs >/tmp/scaffold-promotion-check-test.log 2>&1)
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || die "self-test: generated TODO check must fail until implemented"
  grep -Fq 'TODO: implement promoted learning check.' /tmp/scaffold-promotion-check-test.log ||
    die "self-test: generated failing check did not print TODO"

  printf 'scaffold-promotion-check self-test passed\n'
}

candidate=""
check_name=""
validate_target="docs"
output_dir="."
self_test=0

while [[ $# -gt 0 ]]; do
  case "$1" in
  --candidate)
    candidate="${2:?--candidate needs a path}"
    shift 2
    ;;
  --check-name)
    check_name="${2:?--check-name needs a slug}"
    shift 2
    ;;
  --validate-target)
    validate_target="${2:?--validate-target needs docs or light}"
    shift 2
    ;;
  --output-dir)
    output_dir="${2:?--output-dir needs a path}"
    shift 2
    ;;
  --self-test)
    self_test=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "unknown argument: $1"
    ;;
  esac
done

if [[ $self_test == 1 ]]; then
  self_test
  exit 0
fi

[[ -n $candidate ]] || die "--candidate is required"
[[ -n $check_name ]] || die "--check-name is required"
scaffold "$candidate" "$check_name" "$validate_target" "$output_dir"
