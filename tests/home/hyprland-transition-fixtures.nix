# Small real Home Manager generations for the host-side, off-screen transition test.
# No activation is performed by a Nix build. The caller supplies a private home.
{ flake, homeDirectory }:
let
  pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
  inherit (pkgs) lib;
  palette = import ../../home/theme/themes/cold-concrete.nix;
  # Consume real production definitions so deleting either installed entrypoint
  # or palette format breaks this fixture, rather than testing a parallel copy.
  files = flake.nixosConfigurations.main.config.home-manager.users.user.xdg.configFile;
  # Suppress legacy autostart only: never start host user services/polkit in a test.
  legacyText = lib.concatStringsSep "\n" (
    builtins.filter (line: !(lib.hasPrefix "exec" line)) (
      lib.splitString "\n" (builtins.readFile files."hypr/hyprland.conf".source)
    )
  );
  make =
    dual:
    (flake.inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        {
          home = {
            username = "user";
            inherit homeDirectory;
            stateVersion = "25.05";
          };
          systemd.user.startServices = false;
          xdg.enable = true;
          xdg.configFile = {
            "hypr/hyprland.conf".text = legacyText;
            "hypr/colors.conf".text = files."themes/cold-concrete/hypr-colors.conf".text;
          }
          // lib.optionalAttrs dual {
            "hypr/hyprland.lua".source = files."hypr/hyprland.lua".source;
            "hypr/colors.lua".text = files."themes/cold-concrete/hypr-colors.lua".text;
          };
        }
      ];
    }).activationPackage;
in
{
  legacy = make false;
  dual = make true;
  expectedActiveBorder = palette.colors.amber;
}
