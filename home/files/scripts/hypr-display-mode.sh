#!/bin/bash

set -euo pipefail

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
    hyprctl dispatch moveworkspacetomonitor "${workspace}" "${output}" >/dev/null
  done
}

case "${1:-auto}" in
auto)
  if wait_for_external; then
    hyprctl keyword monitor "${external_output},preferred,0x0,1"
    move_workspaces_to "${external_output}"
    hyprctl keyword monitor "${internal_output},disable"
  else
    hyprctl keyword monitor "${internal_output},preferred,0x0,1"
    move_workspaces_to "${internal_output}"
  fi
  ;;
external)
  hyprctl keyword monitor "${external_output},preferred,0x0,1"
  move_workspaces_to "${external_output}"
  hyprctl keyword monitor "${internal_output},disable"
  ;;
laptop)
  hyprctl keyword monitor "${internal_output},preferred,0x0,1"
  move_workspaces_to "${internal_output}"
  if external_connected; then
    hyprctl keyword monitor "${external_output},preferred,1920x0,1"
  fi
  ;;
*)
  echo "usage: hypr-display-mode [auto|external|laptop]" >&2
  exit 2
  ;;
esac
