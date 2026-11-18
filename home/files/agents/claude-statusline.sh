# shellcheck shell=bash
# Claude Code status line: model | cwd | context | rate limits.
#
# Claude Code hands its usage limits only to the status line, so this also
# records them for the quiet shell's agents card: the account's limits in
# claude.json, and one small file per session naming the process that runs it,
# which the card lists while that process is alive.
# Writing is best effort; the status line never fails because of it.

input=$(cat)

state="${XDG_STATE_HOME:-$HOME/.local/state}/agent-usage"
record() {
  mkdir -p "$state/claude-sessions" || return
  local now
  now=$(date +%s)
  # Each file is written whole and renamed, so the shell never reads half of one.
  if jq -e '.rate_limits.five_hour // .rate_limits.seven_day' <<<"$input" >/dev/null 2>&1; then
    jq --argjson at "$now" '{at: $at, rate_limits}' <<<"$input" >"$state/claude.json.tmp" &&
      mv "$state/claude.json.tmp" "$state/claude.json"
    # A line whenever a limit moves, so the board can tell how fast each is
    # spent. The last few thousand changes are plenty for a week.
    local sample last
    sample=$(jq -c '[.rate_limits.five_hour.used_percentage, .rate_limits.seven_day.used_percentage]' <<<"$input")
    last=$(tail -n 1 "$state/claude-history.jsonl" 2>/dev/null | jq -c '[.five, .week]' 2>/dev/null)
    if [ "$sample" != "$last" ]; then
      jq -c --argjson at "$now" '{at: $at, five: .[0], week: .[1]}' <<<"$sample" >>"$state/claude-history.jsonl"
      if [ "$(wc -l <"$state/claude-history.jsonl")" -gt 4000 ]; then
        tail -n 2000 "$state/claude-history.jsonl" >"$state/claude-history.jsonl.tmp" &&
          mv "$state/claude-history.jsonl.tmp" "$state/claude-history.jsonl"
      fi
    fi
  fi
  local id
  id=$(jq -r '.session_id // empty' <<<"$input" | tr -cd 'A-Za-z0-9-')
  [ -n "$id" ] || return
  # The Claude process that owns this session: the nearest ancestor that is not
  # a shell. With its start time and the boot id, the card can tell whether the
  # session is still running instead of guessing from the file's age.
  local pid=$PPID comm stat
  while [ "$pid" -gt 1 ]; do
    comm=$(cat "/proc/$pid/comm") || return
    case $comm in
    sh | bash | dash | zsh) pid=$(awk '{ print $4 }' "/proc/$pid/stat") || return ;;
    *) break ;;
    esac
  done
  stat=$(cat "/proc/$pid/stat") || return
  stat=${stat##*) }
  jq --argjson at "$now" \
    --argjson pid "$pid" \
    --arg started "$(awk '{ print $20 }' <<<"$stat")" \
    --arg boot "$(cat /proc/sys/kernel/random/boot_id)" '{
      id: .session_id,
      at: $at,
      pid: $pid,
      started: $started,
      boot: $boot,
      cwd: (.workspace.current_dir // .cwd // ""),
      project: (.workspace.project_dir // ""),
      model: (.model.display_name // ""),
      context: (.context_window.used_percentage // null),
      cost: (.cost.total_cost_usd // null),
      transcript: (.transcript_path // ""),
      lines: ((.cost.total_lines_added // 0) + (.cost.total_lines_removed // 0))
    }' <<<"$input" >"$state/claude-sessions/$id.json.tmp" &&
    mv "$state/claude-sessions/$id.json.tmp" "$state/claude-sessions/$id.json"
  # Sessions quiet for a day are over.
  find "$state/claude-sessions" -name '*.json' -mmin +1440 -delete 2>/dev/null
}
record 2>/dev/null || true

model=$(jq -r '.model.display_name // "unknown"' <<<"$input")
cwd=$(jq -r '.workspace.current_dir // .cwd // ""' <<<"$input")
used_pct=$(jq -r '.context_window.used_percentage // empty' <<<"$input")
five_pct=$(jq -r '.rate_limits.five_hour.used_percentage // empty' <<<"$input")
week_pct=$(jq -r '.rate_limits.seven_day.used_percentage // empty' <<<"$input")

cwd="${cwd/#$HOME/\~}"

RESET='\033[0m'
BOLD='\033[1m'
CYAN='\033[36m'
YELLOW='\033[33m'
GREEN='\033[32m'
RED='\033[31m'
DIM='\033[2m'

# Green, yellow or red by how much is left.
shade() {
  if [ "$1" -le "$2" ]; then
    printf '%s' "$RED"
  elif [ "$1" -le "$3" ]; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

printf "${BOLD}${CYAN}%s${RESET}" "$model"
printf " ${DIM}|${RESET} ${YELLOW}%s${RESET}" "$cwd"

if [ -n "$used_pct" ]; then
  used_int=$(printf '%.0f' "$used_pct")
  printf " ${DIM}|${RESET} ctx:%b%s%%${RESET}" "$(shade $((100 - used_int)) 20 50)" "$used_int"
fi

for pair in "5h:$five_pct" "7d:$week_pct"; do
  label=${pair%%:*}
  pct=${pair#*:}
  [ -n "$pct" ] || continue
  left=$(awk -v p="$pct" 'BEGIN { printf "%.0f", 100 - p }')
  printf " ${DIM}|${RESET} %s:%b%s%%${RESET}" "$label" "$(shade "$left" 20 50)" "$left"
done

printf '\n'
