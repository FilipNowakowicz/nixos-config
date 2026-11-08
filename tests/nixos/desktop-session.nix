# Boots the real Home Manager desktop module and follows a session through login,
# a crash, logout and login again. quiet-shell-smoke.nix covers what the shell can
# do; this covers the units, activation and environment that start it on `main`.
{
  nixpkgs,
  system,
  home-manager,
}:
let
  pkgs = import nixpkgs { inherit system; };
  uid = 1000;
in
(import "${nixpkgs}/nixos/lib/testing-python.nix" {
  inherit system pkgs;
}).runTest
  {
    name = "desktop-session";

    nodes.machine = {
      imports = [ home-manager.nixosModules.home-manager ];

      virtualisation = {
        memorySize = 2048;
        qemu.options = [
          "-vga none"
          "-device virtio-gpu-pci"
        ];
      };
      hardware.graphics.enable = true;
      programs.hyprland.enable = true;

      users.users.user = {
        isNormalUser = true;
        inherit uid;
      };
      services.getty.autologinUser = "user";
      # The greeter's job. /tmp/hold keeps the next login waiting, so the test can
      # see the logged-out state before the automatic login replaces it.
      programs.bash.loginShellInit = ''
        if [ "$(tty)" = /dev/tty1 ]; then
          while [ -e /tmp/hold ]; do sleep 1; done
          exec ${pkgs.hyprland}/bin/start-hyprland > /tmp/hyprland.log 2>&1
        fi
      '';

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        users.user = {
          imports = [ ../../home/desktop ];
          home = {
            username = "user";
            homeDirectory = "/home/user";
            stateVersion = "24.11";
          };
          themes.activeFile = "/home/user/active.nix";
        };
      };
    };

    testScript = ''
      theme = "acid-statue"
      units = ["graphical-session.target", "tray-watcher.service", "quiet-shell.service", "hypridle.service"]

      def user(cmd):
          return f"su user -c 'XDG_RUNTIME_DIR=/run/user/${toString uid} {cmd}'"

      def wait_for_session():
          try:
              for unit in units:
                  machine.wait_until_succeeds(user(f"systemctl --user is-active {unit}"), timeout=120)
          except Exception:
              print(machine.execute(user("systemctl --user list-units --all --no-pager; systemctl --user status --no-pager -n 30 quiet-shell tray-watcher hypridle graphical-session.target hyprland-session.target; systemctl --user show-environment"))[1])
              print(machine.execute("cat /tmp/hyprland.log; tail -n 40 /run/user/${toString uid}/hypr/*/hyprland.log; systemctl status --no-pager home-manager-user; journalctl -b -u home-manager-user --no-pager | tail -30")[1])
              raise

      def env(name):
          out = machine.succeed(user("systemctl --user show-environment"))
          return next(l.split("=", 1)[1] for l in out.splitlines() if l.startswith(name + "="))

      def main_pid():
          return machine.succeed(user("systemctl --user show -p MainPID --value quiet-shell.service")).strip()

      machine.wait_for_unit("multi-user.target")

      with subtest("login starts the desktop with the compositor's environment"):
          wait_for_session()
          first = env("HYPRLAND_INSTANCE_SIGNATURE")
          assert env("WAYLAND_DISPLAY").startswith("wayland-")

      with subtest("a crashed shell comes back"):
          before = main_pid()
          machine.succeed(user("systemctl --user kill -s KILL quiet-shell.service"))
          machine.wait_until_succeeds(
              user(f"test \"$(systemctl --user show -p MainPID --value quiet-shell.service)\" != 0 -a \"$(systemctl --user show -p MainPID --value quiet-shell.service)\" != {before}"),
              timeout=60,
          )

      with subtest("logout stops the desktop"):
          machine.succeed("touch /tmp/hold")
          machine.succeed(user(f"HYPRLAND_INSTANCE_SIGNATURE={first} hyprctl dispatch \"hl.dsp.exit()\""))
          for unit in units:
              machine.wait_until_fails(user(f"systemctl --user is-active {unit}"), timeout=60)

      with subtest("logging in again starts it with a fresh environment"):
          machine.succeed("rm /tmp/hold")
          wait_for_session()
          machine.wait_until_succeeds(user(f"systemctl --user show-environment | grep HYPRLAND_INSTANCE_SIGNATURE= | grep -v {first}"), timeout=60)

      with subtest("a theme switch stays out of the repo and survives activation"):
          signature = env("HYPRLAND_INSTANCE_SIGNATURE")
          machine.succeed("su user -c 'mkdir ~/themes; touch ~/themes/%s.nix'" % theme)
          machine.succeed(user(f"HYPRLAND_INSTANCE_SIGNATURE={signature} WAYLAND_DISPLAY=wayland-1 /etc/profiles/per-user/user/bin/theme-switch {theme}"))
          assert machine.succeed("cat /home/user/.local/state/theme/active").strip() == theme
          machine.fail("test -e /home/user/active.nix")
          machine.succeed("systemctl restart home-manager-user.service")
          assert f"/themes/{theme}/" in machine.succeed("readlink /home/user/.config/hypr/colors.lua")
    '';
  }
