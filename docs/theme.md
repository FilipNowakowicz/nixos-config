# Runtime Theme System

The desktop color system is runtime-swappable: changing themes relinks
pre-generated assets and reloads running apps without a NixOS rebuild. This
document covers the data flow, the color contract, and the single-source-of-truth
guarantee.

## Components

- `home/theme/themes/*.nix` — one file per theme; the source palette.
- `home/theme/active.nix` — a one-line pointer (`import ./themes/<name>.nix`)
  naming the default theme. Runtime choices live in
  `~/.local/state/theme/active` and take precedence over it.
- `home/theme/module.nix` — the Home Manager module. Auto-discovers themes,
  validates them, renders every theme's app configs at build time, and ships the
  `theme-switch` runtime switcher.
- `home/files/scripts/theme-switch.sh` — the runtime switcher's script body,
  wrapped by the module (which injects the paths it needs).

## Color contract

Each theme is a small Nix attrset:

- `name` — must match the filename (without `.nix`).
- `displayName` — the title the shell picker shows.
- `colors` — the five-slot palette, plain hex without `#`: `bg`, `surface`
  (panels, inactive borders), `secondary` (a second accent: bells, warnings),
  `accent` (focus, cursor, highlights, Neovim functions) and `text`. The module
  rejects a theme with a missing, unknown or non-hex slot.
- `ansiColors` — a 16-slot ANSI palette (`color0`…`color15`) for the terminal.
- `appearance` — `"dark"` (the default) or `"light"`.
- `wallpaper` — a path under `home/theme/wallpapers/`.

## Build time (Nix is the single source of truth)

`home/theme/module.nix` discovers every enabled theme whose wallpaper exists and,
for each, generates under `~/.config/themes/<name>/`:

- `kitty-theme.conf`, `hypr-colors.lua`, `hyprlock-colors.conf`,
  `zathura-colors`, a `wallpaper` symlink,
- `quiet-colors.json` — the shell's colours plus every theme's title, palette
  and a wallpaper thumbnail for its picker,
- `nvim-palette.lua` — a base16 scheme derived from `colors` and `ansiColors`,
  which Neovim applies with `mini.base16` (`home/files/nvim/lua/config/theme.lua`),
  and
- `vars` — a shell-sourceable file (`bg=…`, `accent=…`, …) consumed by the
  runtime switcher.

It also emits `~/.config/themes/links.sh` (the symlink map) and a Home Manager
activation hook that re-reads the runtime choice on every activation, so a
switch survives a rebuild that was built against a different theme.

The active theme defaults to whatever `active.nix` selects (the module reads it
directly), so there is no separate `themes.active` wiring to keep in sync.

## Runtime (`theme-switch`)

`theme-switch <name>`:

1. validates the theme exists in the repo and that its assets are built;
2. records the choice in `~/.local/state/theme/active` so it persists across
   rebuilds, without touching the repo;
3. sources `links.sh` and relinks the pre-generated assets into live app paths;
4. sources the generated `vars` file for the colors it needs;
5. sets GTK and the settings portal (so Firefox) to dark or light through the
   `gtk-theme` and `color-scheme` dconf keys, which the module owns: activation
   re-applies the running theme's appearance after Home Manager's dconf load;
6. reloads Hyprland, Quiet Shell, Kitty, Neovim (SIGUSR1) and the wallpaper
   in place.

Because the switcher consumes the **same** Nix-generated assets and `vars` file
that a rebuild produces — rather than re-deriving colors by parsing theme `.nix`
files — a runtime switch and a rebuild always yield identical results. The
`theme-module` flake check (`tests/home/theme-module.nix`) enforces this by
asserting the generated `vars` and Kitty palette match the theme definition.

## Adding a theme

1. Add `home/theme/themes/<name>.nix` and `home/theme/wallpapers/<name>.<ext>`.
   Encode the wallpaper once at no more than twice the screen size, as
   high-quality JPEG unless it is flat enough that a PNG is smaller:
   `magick in.png -strip -resize '3840x2160^>' -quality 92 -interlace JPEG <name>.jpg`.
   Git keeps every version of a binary forever.
2. Rebuild so Home Manager generates its assets.
3. `theme-switch <name>`, or `theme-switch --save <name>` to also make it the
   default in `active.nix` for machines with no runtime choice yet.

## Public module (`homeModules.runtime-theme`)

The module is exposed as a flake output so other Home Manager configs running
the same desktop (Hyprland + Quiet Shell + Kitty + Hyprlock) can reuse it. It
is an **opinionated** module for that stack — the color contract, templates, and
reload mechanics are fixed — not a generic theming framework.

```nix
# flake.nix
{
  inputs.nixos-fleet.url = "github:FilipNowakowicz/nixos-config";
}
```

```nix
# in a Home Manager module
{ inputs, ... }:
{
  imports = [ inputs.nixos-fleet.homeModules.runtime-theme ];

  themes = {
    # Your own theme set: a directory with themes/,
    # and active.nix. Defaults to this repo's home/theme.
    themeDir = ./theme;

    # Working-tree active.nix that `theme-switch --save` rewrites. Point it
    # at a file your config repo tracks.
    activeFile = "/home/you/dotfiles/theme/active.nix";

    # Optional: override the build-time default (otherwise read from active.nix).
    # active = "mono-mesh";
  };
}
```

Importing the module activates it and adds `theme-switch` to `home.packages`
(consistent with the repo's other `homeModules`, which activate on import). The
neovim module finds the live palette through the internal
`themes._nvimPaletteFile` option.

### What it reloads (`desktop-runtime.nix`)

`theme-switch` regenerates and live-reloads a fixed set of Wayland UI tools:
**kitty** and **swaybg**. That list lives in one place,
[`home/profiles/desktop-runtime.nix`](../home/profiles/desktop-runtime.nix), and
is imported by both the module's `theme-switch` `runtimeInputs` and the desktop
install list (`home/profiles/desktop.nix`), so the packages you install and the
packages the switcher reloads cannot drift. If you adopt `runtime-theme` on the
same stack, install these packages too; the no-drift contract is pinned by the
`theme-module` check (`testRuntimeThemeContract`).

Out of scope for now (still coupled to this exact desktop): per-app enable
toggles and a generic, app-agnostic template interface.
