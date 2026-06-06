#!/usr/bin/env bash
# Validate compact learning-candidate routing metadata.
set -euo pipefail

root=${1:-.agents/learning}
candidate_dir="$root/candidates"
rc=0

# Minimal set a reviewer needs to triage and reopen the source. Everything
# else (agent, type, dedupe_key, triggers, targets, risk) is optional and only
# improves routing when present — keep capture cheap.
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

allowed_type='^(behavior-upgrade|repo-fix|workflow-gotcha|policy-gap)$'
allowed_route='^(implement-fix|promote-memory|promote-skill|promote-hook|promote-doc|reject)$'
allowed_best_form='^(invariant|test|ci-gate|hook|skill|doc|none)$'
allowed_status='^(open|promoted|rejected|superseded|expired)$'

[ -d "$candidate_dir" ] || exit 0

while IFS= read -r path; do
  case "$path" in
  *.yml | *.yaml) ;;
  *)
    printf 'learning candidate must be compact YAML: %s\n' "$path" >&2
    rc=1
    continue
    ;;
  esac

  for field in "${required_fields[@]}"; do
    if grep -Eq "^${field}:[[:space:]]*.+" "$path"; then
      continue
    fi
    # Candidates are single-line compact YAML; the field check is a same-line
    # grep. A key present with a block-style (next-line) value still fails, so
    # distinguish that from a truly absent field to avoid a misleading error.
    if grep -Eq "^${field}:[[:space:]]*$" "$path"; then
      printf '%s: field %s must be single-line compact YAML (value on the same line as the key)\n' "$path" "$field" >&2
    else
      printf '%s: missing required field %s\n' "$path" "$field" >&2
    fi
    rc=1
  done

  if ! grep -Eq '^schema:[[:space:]]*learning-candidate/v1$' "$path"; then
    printf '%s: schema must be learning-candidate/v1\n' "$path" >&2
    rc=1
  fi

  if ! sed -n 's/^status:[[:space:]]*//p' "$path" | head -1 | grep -Eq "$allowed_status"; then
    printf '%s: invalid status\n' "$path" >&2
    rc=1
  fi

  # type is optional; validate only when present.
  if grep -Eq '^type:[[:space:]]*.+' "$path" &&
    ! sed -n 's/^type:[[:space:]]*//p' "$path" | head -1 | grep -Eq "$allowed_type"; then
    printf '%s: invalid type\n' "$path" >&2
    rc=1
  fi

  if ! sed -n 's/^route:[[:space:]]*//p' "$path" | head -1 | grep -Eq "$allowed_route"; then
    printf '%s: invalid route\n' "$path" >&2
    rc=1
  fi

  if ! sed -n 's/^best_form:[[:space:]]*//p' "$path" | head -1 | grep -Eq "$allowed_best_form"; then
    printf '%s: invalid best_form\n' "$path" >&2
    rc=1
  fi
done < <(find "$candidate_dir" -maxdepth 1 -type f ! -name '.gitkeep' | sort)

exit "$rc"
