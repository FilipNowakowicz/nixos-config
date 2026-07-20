#!/bin/bash
# shellcheck disable=SC2016  # --preview body expands later, in fzf's own shell
# Image entries come from cliphist-images.service (wl-paste --type image), so
# any "binary data" preview line is always an image - safe to icat directly.
selected=$(cliphist list | fzf \
  --prompt="Clipboard: " \
  --reverse \
  --preview-window="right:60%:wrap" \
  --preview '
    line={}
    if [[ $line == *"binary data"* ]]; then
      f=$(mktemp)
      trap "rm -f \"\$f\"" EXIT
      cliphist decode <<<"$line" >"$f"
      kitty +kitten icat --transfer-mode=memory --stdin=no --unicode-placeholder \
        --image-id=1 --place="${FZF_PREVIEW_COLUMNS}x${FZF_PREVIEW_LINES}@0x0" "$f" 2>/dev/null
    else
      cliphist decode <<<"$line"
    fi
  ')

[[ -n $selected ]] && cliphist decode <<<"$selected" | wl-copy
