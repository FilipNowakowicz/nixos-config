#!/usr/bin/env bash
# Promoted from .agents/learning/candidates/archive/2026-11-15-hyprctl-legacy-dispatch-dead-under-lua.yml
# Under the Lua config, `hyprctl dispatch` takes an hl.dsp expression and
# `hyprctl keyword` no longer exists. A legacy `hyprctl dispatch dpms on` in
# hypridle failed silently and left the screen dark after resume. Reject the
# legacy forms anywhere the desktop's commands are written.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Scanned with find, not git ls-files: validate.sh can run on the builder, which
# gets the tree without .git.
mapfile -t files < <(find home packages hosts tests -type f \( -name '*.nix' -o -name '*.sh' -o -name '*.lua' -o -name '*.qml' -o -name '*.py' \))
if ((${#files[@]} < 50)); then
  echo "no-legacy-hyprctl-dispatch: only ${#files[@]} files found; refusing to pass on a near-empty scan" >&2
  exit 1
fi

# `hyprctl dispatch` must be followed by a quote (possibly escaped) and `hl.`.
# Comments are skipped: they may name the old form to explain the new one.
if grep -nE 'hyprctl[[:space:]]+(dispatch[[:space:]]+[^[:space:]]|keyword[[:space:]])' "${files[@]}" |
  grep -vE 'hyprctl[[:space:]]+dispatch[[:space:]]+\\?["'"'"']hl\.' |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//|--)'; then
  echo "no-legacy-hyprctl-dispatch: use \`hyprctl dispatch 'hl.dsp...'\` or \`hyprctl eval\` under the Lua config" >&2
  exit 1
fi
