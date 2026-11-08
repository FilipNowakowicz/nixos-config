#!/bin/bash

set -euo pipefail

# Hotplug events arrive in bursts, and applying a policy causes more of them.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/hypr-display-mode.lock"
flock -w 20 9

# Probe the running parser, not the installed package or config filenames.
# During a rebuild the old compositor can outlive the package/config switch.
lua_config=false
if [[ $(hyprctl eval 'assert(type(hl) == "table")' 2>/dev/null) == ok ]]; then
  lua_config=true
fi

external_output="DVI-I-1"
internal_output="eDP-1"

external_connected() {
  hyprctl monitors 2>/dev/null | grep -q "^Monitor ${external_output} "
}

wait_for_external() {
  for _ in $(seq 1 30); do
    if external_connected; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

move_workspaces_to() {
  local output="$1"

  for workspace in $(seq 1 10); do
    if $lua_config; then
      hyprctl dispatch "hl.dsp.workspace.move({workspace=${workspace},monitor='${output}'})" >/dev/null
    else
      hyprctl dispatch moveworkspacetomonitor "$workspace" "$output" >/dev/null
    fi
  done
}

set_monitor() {
  local output="$1" mode="$2" position="${3:-auto}" reply
  if $lua_config; then
    if [[ $mode == disable ]]; then
      reply=$(hyprctl eval "hl.monitor({output='$output',disabled=true})")
    else
      reply=$(hyprctl eval "hl.monitor({output='$output',mode='$mode',position='$position',scale=1,disabled=false})")
    fi
  else
    if [[ $mode == disable ]]; then
      reply=$(hyprctl keyword monitor "$output,disable")
    else
      reply=$(hyprctl keyword monitor "$output,$mode,$position,1")
    fi
  fi
  [[ $reply == ok ]] || {
    echo "$reply" >&2
    return 1
  }
}

use_external() {
  set_monitor "${external_output}" highrr 0x0
  move_workspaces_to "${external_output}"
  set_monitor "$internal_output" disable
}

use_internal() {
  set_monitor "${internal_output}" preferred 0x0
  move_workspaces_to "${internal_output}"
}

case "${1:-auto}" in
auto)
  if wait_for_external; then use_external; else use_internal; fi
  ;;
# Already told the monitors changed, so don't wait the way startup has to.
hotplug)
  if external_connected; then use_external; else use_internal; fi
  ;;
external)
  use_external
  ;;
laptop)
  set_monitor "${internal_output}" preferred 0x0
  move_workspaces_to "${internal_output}"
  if external_connected; then
    set_monitor "${external_output}" highrr 1920x0
  fi
  ;;
*)
  echo "usage: hypr-display-mode [auto|hotplug|external|laptop]" >&2
  exit 2
  ;;
esac
