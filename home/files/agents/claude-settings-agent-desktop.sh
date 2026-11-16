# shellcheck shell=bash
# Merge the Agent Desktop host-approval hook into Claude Code's user settings.
# Usage: claude-settings-agent-desktop SETTINGS_JSON GUARD FILTER
#
# Claude Code writes this file itself, so Home Manager cannot own it; this edits
# it in place. An unreadable file is left untouched with a warning: without the
# merge there is no variable either, and Agent Desktop keeps asking by its own
# notification.

settings=$1
guard=$2
filter=$3

mkdir -p "$(dirname "$settings")"
[ -s "$settings" ] || printf '{}\n' >"$settings"

tmp=$(mktemp "$settings.XXXXXX")
trap 'rm -f "$tmp"' EXIT
if ! jq --arg guard "$guard" -f "$filter" "$settings" >"$tmp"; then
  echo "agent-desktop: $settings is not valid JSON; host-approval hook not installed" >&2
  exit 0
fi
chmod --reference="$settings" "$tmp"
mv "$tmp" "$settings"
