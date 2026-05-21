#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-secrets-directory.sh [--staged|--working-tree]

Validate files under:
- hosts/*/secrets/*
- home/users/user/secrets/*

Allowed:
- encrypted blobs ending in .enc or .age
- JSON/YAML files ending in .json, .yaml, or .yml that contain a top-level SOPS block
EOF
}

mode="${1:---working-tree}"

case "$mode" in
--staged | --working-tree) ;;
-h | --help)
  usage
  exit 0
  ;;
*)
  usage >&2
  exit 1
  ;;
esac

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"

cd "$repo_root"

has_failed=0

file_contents() {
  local path="$1"

  if [[ $mode == "--staged" ]]; then
    git show ":$path" 2>/dev/null
  else
    cat "$path"
  fi
}

has_sops_yaml_block() {
  grep -Eq '^sops:[[:space:]]*$'
}

has_sops_json_block() {
  awk '
    function brace_delta(line,    stripped) {
      stripped = line
      gsub(/"([^"\\]|\\.)*"/, "\"\"", stripped)
      return gsub(/{/, "{", stripped) - gsub(/}/, "}", stripped)
    }
    depth == 1 && $0 ~ /^[[:space:]]*"sops"[[:space:]]*:/ {
      found = 1
      exit
    }
    {
      depth += brace_delta($0)
    }
    END {
      exit found ? 0 : 1
    }
  '
}

has_plaintext_secret_marker() {
  grep -E \
    -e 'github_pat_[A-Za-z0-9_]{20,}' \
    -e 'gh[pousr]_[A-Za-z0-9_]{20,}' \
    -e 'ya29\.[A-Za-z0-9._-]{20,}' \
    -e 'sk-(proj-)?[A-Za-z0-9_-]{20,}' \
    -e 'xox[baprs]-[A-Za-z0-9-]{20,}' \
    -e 'glpat-[A-Za-z0-9_-]{20,}' \
    -e 'AKIA[0-9A-Z]{16}' \
    -e 'age-secret-key-[a-z0-9]{50,}'
}

validate_sops_file() {
  local path="$1"
  local type="$2"
  local has_sops=1

  case "$type" in
  json)
    if file_contents "$path" | has_sops_json_block; then
      has_sops=0
    fi
    ;;
  yaml)
    if file_contents "$path" | has_sops_yaml_block; then
      has_sops=0
    fi
    ;;
  esac

  if [[ $has_sops -ne 0 ]]; then
    echo "Plaintext ${type^^} is not allowed under secrets directories: $path" >&2
    echo "Only SOPS-managed JSON/YAML files with a top-level SOPS block may live there." >&2
    return 1
  fi

  if file_contents "$path" | has_plaintext_secret_marker >/dev/null; then
    echo "Suspicious plaintext token marker found in SOPS-managed secret file: $path" >&2
    echo "Encrypt token values instead of leaving provider tokens visible beside the SOPS block." >&2
    return 1
  fi

  return 0
}

validate_path() {
  local path="$1"

  case "$path" in
  home/users/user/secrets/README.md)
    return 0
    ;;
  *.enc | *.age)
    return 0
    ;;
  *.json)
    validate_sops_file "$path" json
    ;;
  *.yaml | *.yml)
    validate_sops_file "$path" yaml
    ;;
  *)
    echo "Unsupported file in secrets directory: $path" >&2
    echo "Allowed file types are .enc, .age, and SOPS-managed .json/.yaml/.yml." >&2
    return 1
    ;;
  esac
}

while IFS= read -r -d '' path; do
  if ! validate_path "$path"; then
    has_failed=1
  fi
done < <(
  if [[ $mode == "--staged" ]]; then
    git diff --cached --name-only --diff-filter=ACMR -z -- \
      ':(glob)hosts/*/secrets/*' \
      ':(glob)home/users/user/secrets/*'
  else
    find hosts home/users/user/secrets -type f -path '*/secrets/*' -print0 2>/dev/null | sort -z
  fi
)

exit "$has_failed"
