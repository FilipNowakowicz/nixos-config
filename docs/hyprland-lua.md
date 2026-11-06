# Hyprland Lua configuration

Hyprland 0.57 uses `home/files/hypr/hyprland.lua`. Home Manager installs it
alongside the legacy `hyprland.conf` for transition compatibility. Theme generation
retains both `hypr-colors.lua` and `hypr-colors.conf`, with corresponding links under
`~/.config/hypr`. Hyprlock continues to use its existing colour format.

The Lua configuration preserves the existing 51 key and mouse bindings, Dvorak
input, layouts, window rules and workspace gestures. This migration does not
install the separately developed desktop interface prototypes.

## Runtime helpers

Display, layout and theme helpers detect the running parser with a read-only Lua
assertion. Installed binaries and configuration files alone cannot establish which
parser an existing compositor session uses. Helpers retain legacy IPC for older
sessions and use Lua IPC for the new session.

Startup commands run on the compositor start event. The display reload handler
checks for active monitors before launching the display helper, since config
verification can emit the reload event without starting a compositor.

## Validation and rollout

Run the flake evaluation, theme-module check and `main-ci` build for source changes:

```sh
bash scripts/validate.sh flake-eval
nix build .#checks.x86_64-linux.theme-module --no-link
bash scripts/validate.sh host main-ci
```

The reviewed configuration also passed off-screen transition tests with both
0.56.2 and 0.57.0: identical binding registrations, unchanged legacy colours,
layout/display helper effects, and verification without startup side effects.
These tests used private homes, displays and D-Bus sessions.

For the initial upgrade, build the actual `main` closure and install it with
`switch-to-configuration boot`, retaining a known-working generation. Save work
and reboot when convenient. Verify the booted/current closure, compositor version,
Lua parser, `hyprctl configerrors`, bindings and input layout after a fresh login.
A build or boot installation alone is not runtime acceptance.

The initial physical login on 2026-11-05 passed with Hyprland 0.57.0, an active Lua
parser, no configuration errors, 51 bindings and Dvorak input. Docking, lock/unlock
and suspend/resume remain normal-use acceptance checks. Keep compatibility assets
and a working fallback during that settling period.
