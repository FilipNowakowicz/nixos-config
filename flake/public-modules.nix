# The public NixOS and Home Manager modules, in one place.
#
# Each value is a *path*, not `import path`. The module system deduplicates
# imports by path, so a consumer (or this fleet) may import a module both by
# its exported name and transitively through another module without the
# options being declared twice. A path also keeps file names in error traces.
#
# Every module listed here must be self-contained: it imports whatever it
# reads from. The personal hosts consume these through `self.nixosModules.*`
# / `self.homeModules.*`, and `public-modules-standalone` in
# `tests/flake/public-modules.nix` evaluates each one on its own, so a module that relies
# on an option some other file happens to declare fails in CI.
#
# Support tiers (see README "Reusable Outputs"):
# - supported: documented usage, behavioural fixtures, breaking changes noted;
# - preset: the maintainer's own setup, kept importable but free to change.
{
  nixosModules = {
    # supported
    services-hardened = ../modules/nixos/services/hardened.nix;
    observability-stack = ../modules/nixos/profiles/observability;
    observability-client = ../modules/nixos/profiles/observability-client.nix;
    profiles-security = ../modules/nixos/profiles/security.nix;
    # preset
    profiles-base = ../modules/nixos/profiles/base.nix;
    profiles-desktop = ../modules/nixos/profiles/desktop.nix;
  };

  homeModules = {
    # preset
    profiles-base = ../home/profiles/base.nix;
    profiles-desktop = ../home/profiles/desktop.nix;
    profiles-workflow-packs = ../home/profiles/workflow-packs;
    neovim = ../home/neovim/module.nix;
    runtime-theme = ../home/theme/module.nix;
  };
}
