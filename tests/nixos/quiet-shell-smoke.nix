# Boots the real Hyprland Lua config and the packaged quiet shell in a VM, so a
# nixpkgs bump that breaks the Lua API, a Quickshell module or a QML file fails
# merge-gate instead of the next `main` rebuild. The acceptance suite in
# tests/quiet-shell covers interaction; this only proves the desktop comes up.
{ nixpkgs, system }:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (nixpkgs) lib;

  quietShell = pkgs.callPackage ../../packages/quiet-shell { };

  # The theme module generates the colour files the config and shell read at
  # runtime; evaluate it against a stub, as tests/home/theme-module.nix does.
  theme =
    (import ../../home/theme/module.nix {
      inherit lib pkgs;
      config = {
        themes = {
          active = "mono-mesh";
          themeDir = ../../home/theme;
          activeFile = "/home/user/active.nix";
        };
        home.homeDirectory = "/home/user";
        xdg.configHome = "/home/user/.config";
      };
    }).config.xdg.configFile;
  hyprColors = pkgs.writeText "colors.lua" theme."themes/mono-mesh/hypr-colors.lua".text;
  shellColors = pkgs.writeText "colors.json" theme."themes/mono-mesh/quiet-colors.json".text;

  uid = 1000;
  runtime = "/run/user/${toString uid}";
  # Runs a command as the desktop user inside the Hyprland session.
  inSession = pkgs.writeShellScript "in-session" ''
    export XDG_RUNTIME_DIR=${runtime} WAYLAND_DISPLAY=wayland-1
    HYPRLAND_INSTANCE_SIGNATURE=$(ls ${runtime}/hypr | head -n 1)
    export HYPRLAND_INSTANCE_SIGNATURE
    exec "$@"
  '';
in
(import "${nixpkgs}/nixos/lib/testing-python.nix" {
  inherit system pkgs;
}).runTest
  {
    name = "quiet-shell-smoke";

    nodes.machine = {
      virtualisation = {
        memorySize = 2048;
        qemu.options = [
          "-vga none"
          "-device virtio-gpu-pci"
        ];
      };
      hardware.graphics.enable = true;
      programs.hyprland.enable = true;
      fonts.packages = [ pkgs.inter ];

      users.users.user = {
        isNormalUser = true;
        inherit uid;
      };
      services.getty.autologinUser = "user";
      # Lay out the files Home Manager would link on `main`, then start Hyprland
      # the way the greeter does.
      programs.bash.loginShellInit = ''
        if [ "$(tty)" = /dev/tty1 ]; then
          mkdir -p ~/.config/hypr ~/.config/quiet-shell
          ln -sf ${../../home/files/hypr/hyprland.lua} ~/.config/hypr/hyprland.lua
          ln -sf ${hyprColors} ~/.config/hypr/colors.lua
          ln -sf ${shellColors} ~/.config/quiet-shell/colors.json
          exec ${pkgs.hyprland}/bin/start-hyprland > /tmp/hyprland.log 2>&1
        fi
      '';
      environment.systemPackages = [ quietShell ];
    };

    testScript = ''
      import json
      from datetime import timedelta

      def session(cmd):
          return machine.succeed(f"su user -c '${inSession} {cmd}'")

      def state():
          return json.loads(session("quiet-shell-ipc state"))

      def wait_for(check, what):
          # Panels animate in, slowly under software rendering, before the picture.
          retry(lambda _: check(state()), timeout=timedelta(seconds=20))
          machine.sleep(timedelta(seconds=2))
          machine.screenshot(what)

      machine.wait_for_unit("multi-user.target")
      status, _ = machine.execute("for _ in $(seq 60); do test -e ${runtime}/wayland-1 && exit 0; sleep 1; done; exit 1")
      if status != 0:
          print(machine.execute("cat /tmp/hyprland.log; tail -n 60 ${runtime}/hypr/*/hyprland.log")[1])
          raise AssertionError("Hyprland did not start")

      with subtest("the real Lua config loads without errors"):
          machine.wait_until_succeeds("su user -c '${inSession} hyprctl monitors' | grep -q Monitor", timeout=timedelta(seconds=60))
          errors = session("hyprctl configerrors").strip()
          assert errors in ("", "no errors"), f"config errors: {errors}"

      with subtest("the shell starts and answers IPC"):
          machine.succeed("su user -c '${inSession} setsid quiet-shell > /tmp/shell.log 2>&1 &'")
          machine.wait_until_succeeds("su user -c '${inSession} quiet-shell-ipc state' | grep -q panel", timeout=timedelta(seconds=90))
          assert state()["theme"] == "mono-mesh"

      with subtest("each surface opens and closes"):
          for call, check in [
              ("spotlight", lambda s: s["spotlight"]),
              ("controls", lambda s: s["panel"] == "controls"),
              ("notifications", lambda s: s["panel"] == "notifications"),
              ("overview", lambda s: s["overview"]),
              ("shortcuts", lambda s: s["cheatSheet"]),
          ]:
              session(f"quiet-shell-ipc {call}")
              wait_for(check, call)
              session("quiet-shell-ipc close")

      with subtest("a real key press reaches the shell through Hyprland"):
          # The config's layout is Dvorak, where S sits on the QWERTY semicolon key.
          machine.send_key("meta_l-shift-semicolon")
          wait_for(lambda s: s["screenshot"], "screenshot-picker")
          session("quiet-shell-ipc close")

      with subtest("the shell does not redraw while idle"):
          # A running animation keeps Qt's render loop drawing every frame even
          # when nothing visible changes. With everything closed, the shell
          # should be asleep between status refreshes.
          machine.sleep(timedelta(seconds=3))
          pid = machine.succeed("pgrep -u user -f -- '-p /nix/store/[^ ]*-quiet-shell' | head -n 1").strip()
          ticks = "awk '{print $14 + $15}' /proc/" + pid + "/stat"
          before = int(machine.succeed(ticks))
          machine.sleep(timedelta(seconds=10))
          used = int(machine.succeed(ticks)) - before
          print(f"idle shell used {used} ticks in 10 seconds")
          # Measured: 33 with one hidden spinner running, 2 without.
          assert used < 15, f"idle shell used {used}/1000 ticks in 10 seconds"

      with subtest("nothing failed to load"):
          machine.succeed("pgrep -u user -f quiet-shell")
          # Panels load lazily, so read the log after every one has opened.
          shell_log = machine.succeed("cat /tmp/shell.log")
          assert "Configuration Loaded" in shell_log, shell_log
          # QML errors name the file and line. The VM has no render node, so a
          # dmabuf ERROR there is expected and harmless.
          for bad in (".qml:", "is not a type", "is not installed", "ReferenceError", "TypeError"):
              assert bad not in shell_log, f"shell log reports a failure ({bad}):\n{shell_log}"
    '';
  }
