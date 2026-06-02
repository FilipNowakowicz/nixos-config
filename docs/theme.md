# Runtime Theme System

The desktop color system is runtime-swappable: changing themes relinks
pre-generated assets and reloads running apps without a NixOS rebuild. This
document covers the data flow, the color contract, and the single-source-of-truth
guarantee.

## Components

- `home/theme/themes/*.nix` — one file per theme; the source palette.
- `home/theme/active.nix` — a one-line pointer (`import ./themes/<name>.nix`)
  naming the active theme. **Single source of truth** for which theme is active.
- `home/theme/module.nix` — the Home Manager module. Auto-discovers themes,
  validates them, renders every theme's app configs at build time, and ships the
  `theme-switch` runtime switcher.
- `home/theme/mako-config.template` — Mako config with `@bg@`/`@text@`/`@orange@`
  placeholders, interpolated by the module.
- `home/files/scripts/theme-switch.sh` — the runtime switcher's script body,
  wrapped by the module (which injects the paths it needs).

## Color contract

Each theme is a small Nix attrset:

- `name` — must match the filename (without `.nix`).
- `colors` — the five-slot palette: `bg`, `brown`, `orange`, `amber`, `text`
  (plain hex, no `#`).
- `ansiColors` — a 16-slot ANSI palette (`color0`…`color15`) for the terminal.
- `colorscheme` — Neovim intent (`name`, `background`, and a contrast hint),
  consumed by the neovim module via `themes._activeThemeColorscheme`.
- `wallpaper` — a path under `home/theme/wallpapers/`.

## Build time (Nix is the single source of truth)

`home/theme/module.nix` discovers every enabled theme whose wallpaper exists and,
for each, generates under `~/.config/themes/<name>/`:

- `kitty-theme.conf`, `hypr-colors.conf`, `hyprlock-colors.conf`,
  `waybar-colors.css`, `mako-config`, a `wallpaper` symlink, and
- `vars` — a shell-sourceable file (`bg=…`, `amber=…`, …) consumed by the
  runtime switcher.

It also emits `~/.config/themes/links.sh` (the symlink map) and a Home Manager
activation hook that re-reads `active.nix` on every activation, so a runtime
switch survives a rebuild that was built against a different theme.

The active theme defaults to whatever `active.nix` selects (the module reads it
directly), so there is no separate `themes.active` wiring to keep in sync.

## Runtime (`theme-switch`)

`theme-switch <name>`:

1. validates the theme exists in the repo and that its assets are built;
2. rewrites `active.nix` so the choice persists across rebuilds;
3. sources `links.sh` and relinks the pre-generated assets into live app paths;
4. sources the generated `vars` file for the colors it needs;
5. reloads Hyprland, Waybar, Kitty, Mako, and the wallpaper in place.

Because the switcher consumes the **same** Nix-generated assets and `vars` file
that a rebuild produces — rather than re-deriving colors by parsing theme `.nix`
files — a runtime switch and a rebuild always yield identical results. The
`theme-module` flake check (`tests/home/theme-module.nix`) enforces this by
asserting the generated `vars` and Kitty palette match the theme definition.

## Adding a theme

1. Add `home/theme/themes/<name>.nix` and `home/theme/wallpapers/<name>.<ext>`.
2. Rebuild so Home Manager generates its assets.
3. `theme-switch <name>` (or set it in `active.nix` and rebuild).

## Public module (`homeModules.runtime-theme`)

The module is exposed as a flake output so other Home Manager configs running
the same desktop (Hyprland + Waybar + Kitty + Mako + Hyprlock) can reuse it. It
is an **opinionated** module for that stack — the color contract, templates, and
reload mechanics are fixed — not a generic theming framework.

```nix
# in a Home Manager configuration
{ inputs, ... }:
{
  imports = [ inputs.nixfleet.homeModules.runtime-theme ];

  themes = {
    # Your own theme set: a directory with themes/, mako-config.template,
    # and active.nix. Defaults to this repo's home/theme.
    themeDir = ./theme;

    # Working-tree active.nix that theme-switch rewrites and the activation
    # hook reads, so a runtime switch persists across rebuilds. Point it at a
    # file your config repo tracks.
    activeFile = "/home/you/dotfiles/theme/active.nix";

    # Optional: override the build-time default (otherwise read from active.nix).
    # active = "mono-mesh";
  };
}
```

Importing the module activates it and adds `theme-switch` to `home.packages`
(consistent with the repo's other `homeModules`, which activate on import). The
neovim/GTK colorscheme intent is exposed through the internal
`themes._activeThemeColors` / `themes._activeThemeColorscheme` options.

Out of scope for now (still coupled to this exact desktop): per-app enable
toggles and a generic, app-agnostic template interface.
