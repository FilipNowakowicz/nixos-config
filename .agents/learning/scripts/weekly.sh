#!/usr/bin/env bash
# The weekly learning loop: digest -> miner -> reviewer -> one PR.
#
# usage: weekly.sh [--dry-run | --review-only]
#   --dry-run      digest and miner only; candidates land in the inbox, no PR
#   --review-only  skip the miner; review what is already in the inbox
#
# 1. digest.py condenses the week's Claude and Codex sessions in this repo.
# 2. The miner (Codex by default, Claude Sonnet as fallback; no tools) turns the
#    digest into candidates, which go into the inbox like any other.
# 3. The reviewer (Claude Opus, fresh context, its own worktree of origin/main)
#    verifies candidates against the source and implements or rejects them.
# 4. This script, not a model, archives the decided candidates, commits, pushes
#    and opens the PR. It enables auto-merge only when every changed path is on
#    the agent surface; merge-gate is then the gate. Otherwise the PR waits.
#
# Environment (the Home Manager module sets these):
#   AGENT_LEARNING_REPO     primary checkout to fetch from (default ~/nix)
#   AGENT_LEARNING_WORKTREES  where worktrees live (default ~/.local/share/worktrees/nix)
#   AGENT_LEARNING_MINER    codex|claude (default codex)
#   AGENT_LEARNING_MINER_MODEL (Codex), AGENT_LEARNING_CLAUDE_MINER_MODEL (fallback),
#   AGENT_LEARNING_REVIEWER_MODEL
#   AGENT_LEARNING_NTFY_URL, AGENT_LEARNING_NTFY_TOKEN_FILE, AGENT_LEARNING_NTFY_TAGS
#   AGENT_LEARNING_AUTO_MERGE  1 (default) or 0
set -euo pipefail

mode=full
case ${1:-} in
--dry-run) mode=dry-run ;;
--review-only) mode=review-only ;;
"") ;;
*)
  echo "usage: $0 [--dry-run | --review-only]" >&2
  exit 2
  ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
prompts=$script_dir/../prompts
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$script_dir/common.sh"

repo=${AGENT_LEARNING_REPO:-$HOME/nix}
worktrees=${AGENT_LEARNING_WORKTREES:-$HOME/.local/share/worktrees/nix}
miner=${AGENT_LEARNING_MINER:-codex}
miner_model=${AGENT_LEARNING_MINER_MODEL:-}
reviewer_model=${AGENT_LEARNING_REVIEWER_MODEL:-opus}
auto_merge=${AGENT_LEARNING_AUTO_MERGE:-1}
state=${XDG_STATE_HOME:-$HOME/.local/state}/agent-learning
inbox=$(learning_inbox)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
run=$state/runs/$stamp
mkdir -p "$run" "$inbox" "$state/processed"
# Keep the last 12 runs.
find "$state/runs" -mindepth 1 -maxdepth 1 -type d | sort | head -n -12 | xargs -r rm -rf

log() { printf 'agent-learning: %s\n' "$*" >&2; }

notify() { # $1=title $2=body [$3=priority]
  [[ -n ${AGENT_LEARNING_NTFY_URL:-} && -r ${AGENT_LEARNING_NTFY_TOKEN_FILE:-/nonexistent} ]] || return 0
  curl -fsS --retry 3 \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$(<"$AGENT_LEARNING_NTFY_TOKEN_FILE")") \
    -H "Title: $1" -H "Priority: ${3:-default}" \
    -H "Tags: ${AGENT_LEARNING_NTFY_TAGS:-}" \
    -d "$2" "$AGENT_LEARNING_NTFY_URL" >/dev/null || log "ntfy post failed"
}
on_exit() {
  local rc=$?
  [[ $rc -eq 0 ]] || notify "Learning review failed" "Exit $rc. Logs: journalctl --user -u agent-learning-weekly; run dir $run" high
}
trap on_exit EXIT

# Codex and Claude both emit JSON; pull the structured part out of Claude's
# envelope.
claude_structured() { jq -e '.structured_output // (.result | fromjson)'; }

# ---------------------------------------------------------------- 1. digest
if [[ $mode != review-only ]]; then
  since=$(cat "$state/last-mined" 2>/dev/null || echo $(($(date +%s) - 7 * 86400)))
  python3 -I "$script_dir/digest.py" --repo "$repo" --worktrees "$worktrees" \
    --since "$since" >"$run/digest.md"
  log "digest: $(head -2 "$run/digest.md" | tail -1)"

  # ---------------------------------------------------------------- 2. miner
  {
    cat "$prompts/miner.md"
    printf '\n## KNOWN (open inbox and archive; do not re-propose)\n\n'
    bash "$script_dir/index-candidates.sh" "$inbox" "$(learning_archive)" |
      tail -n +2 | cut -f2,8 | sort -u | tail -n 300
    printf '\n## DIGEST\n\n'
    cat "$run/digest.md"
  } >"$run/miner-prompt.md"

  mine_codex() {
    codex exec ${miner_model:+-m "$miner_model"} -s read-only --ephemeral \
      --skip-git-repo-check -C "$run" \
      --output-schema "$prompts/miner-schema.json" -o "$run/miner.json" - \
      <"$run/miner-prompt.md" >"$run/miner.log" 2>&1
  }
  mine_claude() {
    claude -p --model "${AGENT_LEARNING_CLAUDE_MINER_MODEL:-sonnet}" --tools "" --no-session-persistence \
      --output-format json --json-schema "$(cat "$prompts/miner-schema.json")" \
      <"$run/miner-prompt.md" 2>"$run/miner.log" | claude_structured >"$run/miner.json"
  }
  if [[ $miner == codex ]] && command -v codex >/dev/null && mine_codex; then
    agent=codex
  else
    [[ $miner != codex ]] || log "codex miner failed (see $run/miner.log); falling back to claude"
    mine_claude
    agent=claude
  fi

  today=$(date +%F)
  expires=$(date -d '+90 days' +%F)
  filed=0
  while IFS= read -r c; do
    q() { jq -r "$1" <<<"$c"; }
    id="$today-$(q .slug)"
    {
      printf 'schema: learning-candidate/v2\n'
      printf 'id: %s\ndate: %s\nexpires: %s\nstatus: open\n' "$id" "$today" "$expires"
      printf 'agent: miner-%s\n' "$agent"
      for f in type route best_form dedupe_key cost observation proposed_upgrade; do
        v=$(q ".$f")
        [[ -z $v ]] || printf '%s: %s\n' "$f" "$(jq -Rn --arg v "$v" '$v')"
      done
      printf 'evidence: %s\n' "$(q '.evidence | tojson')"
      printf 'targets: %s\n' "$(q '.targets | tojson')"
    } >"$run/candidate.yml"
    if bash "$script_dir/file-candidate.sh" "$run/candidate.yml" >/dev/null; then
      filed=$((filed + 1))
    else
      log "miner candidate $id failed validation; kept in $run"
      cp "$run/candidate.yml" "$run/invalid-$id.yml"
    fi
  done < <(jq -c '.candidates[]' "$run/miner.json")
  date +%s >"$state/last-mined"
  log "miner ($agent) filed $filed candidates"
fi

if [[ $mode == dry-run ]]; then
  trap - EXIT
  log "dry run: inbox $inbox, run $run"
  exit 0
fi

# ---------------------------------------------------------------- 3. reviewer
if ! find "$inbox" -maxdepth 1 -name '*.yml' | grep -q .; then
  trap - EXIT
  log "inbox empty; nothing to review"
  exit 0
fi

branch=learning-review-$stamp
wt=$worktrees/$branch
git -C "$repo" fetch -q origin main
git -C "$repo" worktree add -q -b "$branch" "$wt" origin/main
cleanup_wt() {
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
}

{
  cat "$prompts/reviewer.md"
  printf '\nInbox: %s\nToday: %s\n' "$inbox" "$(date +%F)"
} >"$run/reviewer-prompt.md"

(cd "$wt" && timeout 3h claude -p --model "$reviewer_model" --no-session-persistence \
  --add-dir "$inbox" \
  --disallowedTools "Bash(git push:*)" "Bash(git commit:*)" "Bash(gh pr:*)" "Bash(gh issue:*)" \
  --output-format json --json-schema "$(cat "$prompts/reviewer-schema.json")" \
  <"$run/reviewer-prompt.md" 2>"$run/reviewer.log") >"$run/reviewer-raw.json"
claude_structured <"$run/reviewer-raw.json" >"$run/reviewer.json"

# ---------------------------------------------------------------- 4. wrapper
archive=$wt/.agents/learning/candidates/archive
mkdir -p "$archive"
decided=()
while IFS=$'\t' read -r id decision reason; do
  src=$inbox/$id.yml
  [[ -f $src ]] || {
    log "reviewer decided on unknown candidate $id; ignored"
    continue
  }
  [[ $decision != deferred ]] || continue
  sed "s/^status:.*/status: $decision/" "$src" >"$archive/$id.yml"
  printf 'resolved: %s\nresolution: %s\n' "$(date +%F)" "$(jq -Rn --arg v "$reason" '$v')" >>"$archive/$id.yml"
  decided+=("$id")
done < <(jq -r '.decisions[] | [.id, .decision, (.reason | gsub("[\t\n]"; " "))] | @tsv' "$run/reviewer.json")

summary=$(jq -r '.decisions | group_by(.decision) | map("\(length) \(.[0].decision)") | join(", ")' "$run/reviewer.json")
git -C "$wt" add -A
if git -C "$wt" diff --cached --quiet; then
  cleanup_wt
  trap - EXIT
  notify "Learning review: no changes" "${summary:-no decisions}"
  exit 0
fi

title=$(jq -r .pr_title "$run/reviewer.json")
{
  jq -r .pr_summary "$run/reviewer.json"
  printf '\n## Decisions\n\n| Candidate | Decision | Why |\n|---|---|---|\n'
  jq -r '.decisions[] | "| `\(.id)` | \(.decision) | \(.reason | gsub("[|\n]"; " ")) |"' "$run/reviewer.json"
  printf '\nOpened by the weekly learning review, agent-learning-weekly.\n'
} >"$run/pr-body.md"

# A worktree never entered through `nix develop` has no pre-commit config;
# merge-gate runs the hooks.
git -C "$wt" commit -q --no-verify -m "$title" -m "Weekly learning review: $summary."
# Push over HTTPS with gh's token: a user service has no SSH agent.
git -C "$wt" -c credential.helper='!gh auth git-credential' \
  push -q "https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)" "$branch"
url=$(cd "$wt" && gh pr create --base main --head "$branch" --title "$title" --body-file "$run/pr-body.md")

agent_surface='^(\.agents/|\.claude/|\.codex/|CLAUDE\.md$|hosts/[^/]+/CLAUDE\.md$|docs/|tests/)'
outside=$(git -C "$wt" diff --name-only HEAD~1 | grep -Ev "$agent_surface" || true)
if [[ $auto_merge == 1 && -z $outside ]]; then
  (cd "$wt" && gh pr merge "$url" --auto --squash --delete-branch)
  verdict="auto-merges when merge-gate passes"
else
  verdict="waiting for you${outside:+ (touches $(tr '\n' ' ' <<<"$outside"))}"
fi

# The PR now carries the decided candidates; drop them from the inbox.
for id in "${decided[@]}"; do mv "$inbox/$id.yml" "$state/processed/"; done
cleanup_wt
trap - EXIT
notify "Learning review: $summary" "$title. $verdict. $url"
log "opened $url ($verdict)"
