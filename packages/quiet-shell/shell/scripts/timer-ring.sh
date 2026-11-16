#!/usr/bin/env bash
# Ring a Spotlight timer or alarm: a notification that stays until dismissed, and
# the alarm sound twice. systemd-run starts this when the timer elapses, so it
# names its tools by absolute path (see default.nix), not the shell's PATH.
# Usage: quiet-timer-ring TITLE [BODY]
notify-send --urgency critical --app-name Timer --icon alarm-symbolic -- "$1" "${2:-}"
sound=${QUIET_ALARM_SOUND:-}
if [ -n "$sound" ] && [ -f "$sound" ]; then
  pw-play "$sound" && pw-play "$sound"
fi
