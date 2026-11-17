#!/usr/bin/env bash
# Ring a Spotlight timer or alarm. systemd-run starts this when the timer elapses,
# and the shell shows a ringing card for as long as this unit runs: Stop and
# Snooze there stop the unit, which ends the sound mid-chime. It gives up by
# itself after two minutes. Its wrapper (default.nix) sets PATH and the sound,
# so it never depends on the shell's PATH.
sound=${QUIET_ALARM_SOUND:-}
end=$((SECONDS + 120))
while [ "$SECONDS" -lt "$end" ]; do
  if [ -n "$sound" ] && [ -f "$sound" ]; then
    pw-play --volume 0.7 "$sound" || sleep 3
  else
    sleep 3
  fi
  sleep 1.5
done
