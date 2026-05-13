#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 {wifi|bluetooth|audio}" >&2
  exit 2
fi

case "$1" in
wifi | bluetooth | audio) ;;
*)
  echo "usage: $0 {wifi|bluetooth|audio}" >&2
  exit 2
  ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python_script="${script_dir}/waybar_widget_preview.py"
gtk4_layer_shell_out="$(nix eval --raw nixpkgs#gtk4-layer-shell.outPath)"

exec nix shell \
  nixpkgs#bash \
  nixpkgs#python3 \
  nixpkgs#python3Packages.pygobject3 \
  nixpkgs#gtk4 \
  nixpkgs#gtk4-layer-shell \
  --command bash -lc '
    export GDK_BACKEND=wayland
    export GTK4_LAYER_SHELL_LIB="'"${gtk4_layer_shell_out}"'/lib/libgtk4-layer-shell.so.0"
    exec python3 "'"${python_script}"'" "'"$1"'"
  '
