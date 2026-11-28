#!/usr/bin/env bash
# Validate compact learning-candidate routing metadata.
#
# usage: validate-candidates.sh [DIR]   (default: the inbox, see common.sh)
#        validate-candidates.sh --self-test
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$script_dir/common.sh"

if [ "${1:-}" = --self-test ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/inbox" "$tmp/archive"
  cat >"$tmp/inbox/a.yml" <<'YAML'
schema: learning-candidate/v2
id: a
date: 2026-01-01
expires: 2026-12-31
status: open
type: tooling-wish
route: promote-subagent
best_form: subagent
cost: 3 CI reruns
evidence: x
observation: x
proposed_upgrade: x
YAML
  if ! LEARNING_ARCHIVE="$tmp/archive" bash "$0" "$tmp/inbox" 2>/dev/null; then
    echo "self-test: valid candidate rejected" >&2
    exit 1
  fi
  cp "$tmp/inbox/a.yml" "$tmp/archive/a.yml"
  if LEARNING_ARCHIVE="$tmp/archive" bash "$0" "$tmp/inbox" 2>/dev/null; then
    echo "self-test: candidate present in both the inbox and archive/ was accepted" >&2
    exit 1
  fi
  rm "$tmp/archive/a.yml"
  sed -i 's/^route: .*/route: promote-everything/' "$tmp/inbox/a.yml"
  if LEARNING_ARCHIVE="$tmp/archive" bash "$0" "$tmp/inbox" 2>/dev/null; then
    echo "self-test: invalid route accepted" >&2
    exit 1
  fi
  printf 'validate-candidates self-test passed\n'
  exit 0
fi

candidate_dir=${1:-$(learning_inbox)}
archive_dir=$(learning_archive)
rc=0

# Minimal set a reviewer needs to triage and reopen the source. Everything
# else (agent, type, cost, dedupe_key, triggers, targets, risk) is optional and
# only improves routing when present; keep capture cheap.
required_fields=(
  schema
  id
  date
  expires
  status
  route
  best_form
  evidence
  observation
  proposed_upgrade
)

allowed_schema='^learning-candidate/v[12]$'
# tooling-wish: a skill, hook, check or subagent that would have made the work
# cheaper or faster. `cost` says what its absence cost.
allowed_type='^(behavior-upgrade|repo-fix|workflow-gotcha|policy-gap|tooling-wish)$'
allowed_route='^(implement-fix|promote-memory|promote-skill|promote-hook|promote-subagent|promote-doc|reject)$'
allowed_best_form='^(invariant|test|ci-gate|hook|skill|subagent|doc|none)$'
allowed_status='^(open|promoted|rejected|superseded|expired)$'

[ -d "$candidate_dir" ] || exit 0

value() { sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1 | sed "s/^[\"']//; s/[\"']\$//"; }

while IFS= read -r path; do
  case "$path" in
  *.yml | *.yaml) ;;
  *)
    printf 'learning candidate must be compact YAML: %s\n' "$path" >&2
    rc=1
    continue
    ;;
  esac

  # A resolved candidate must not also sit in the open queue.
  if [ -e "$archive_dir/${path##*/}" ]; then
    printf '%s: also present in archive/; delete the open copy\n' "$path" >&2
    rc=1
  fi

  for field in "${required_fields[@]}"; do
    if ! grep -Eq "^${field}:" "$path"; then
      printf '%s: missing required field %s\n' "$path" "$field" >&2
      rc=1
    fi
  done

  # Candidates are single-line compact YAML. Flag any top-level key written
  # block-style (value on the next line), so the index scripts' same-line grep
  # never silently drops a field.
  while IFS= read -r key; do
    printf '%s: field %s must be single-line compact YAML (value on the same line as the key)\n' "$path" "${key%%:*}" >&2
    rc=1
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$' "$path")

  value schema "$path" | grep -Eq "$allowed_schema" ||
    { printf '%s: schema must be learning-candidate/v1 or v2\n' "$path" >&2 && rc=1; }
  value status "$path" | grep -Eq "$allowed_status" ||
    { printf '%s: invalid status\n' "$path" >&2 && rc=1; }
  if grep -Eq '^type:[[:space:]]*.+' "$path"; then
    value type "$path" | grep -Eq "$allowed_type" ||
      { printf '%s: invalid type\n' "$path" >&2 && rc=1; }
  fi
  value route "$path" | grep -Eq "$allowed_route" ||
    { printf '%s: invalid route\n' "$path" >&2 && rc=1; }
  value best_form "$path" | grep -Eq "$allowed_best_form" ||
    { printf '%s: invalid best_form\n' "$path" >&2 && rc=1; }
done < <(find "$candidate_dir" -maxdepth 1 -type f ! -name '.gitkeep' | sort)

exit "$rc"
