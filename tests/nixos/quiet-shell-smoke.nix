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
    export DBUS_SESSION_BUS_ADDRESS=unix:path=${runtime}/bus XDG_DATA_DIRS=/run/current-system/sw/share
    HYPRLAND_INSTANCE_SIGNATURE=$(ls ${runtime}/hypr | head -n 1)
    export HYPRLAND_INSTANCE_SIGNATURE
    exec "$@"
  '';
  dbusPython = pkgs.python3.withPackages (ps: [ ps.dbus-next ]);
  # Selects the whole screen, as a drag from corner to corner would.
  # Like the real one, it reads window boxes first when stdin isn't a terminal,
  # so a capture that leaves stdin open hangs here too.
  fakeSlurp = pkgs.writeShellScriptBin "slurp" "[ -t 0 ] || cat >/dev/null; echo '0,0 1280x800'";
  # Comes before the real one on PATH. Keeps the country and logs each change.
  fakeMullvad = pkgs.writeShellScriptBin "mullvad" ''
    country=$(cat /tmp/mullvad-country 2>/dev/null || echo se)
    case "$1 ''${2:-}" in
      "status "*)
        if [ -e /tmp/mullvad-on ]; then printf 'Connected\n    Relay:  %s-sto-wg-001\n' "$country"; else echo Disconnected; fi ;;
      "relay get") echo "    Location:  country $country" ;;
      "relay list")
        for place in "Albania (al)" "Sweden (se)" "UK (gb)"; do
          printf '%s\n\tCity (cit) @ 1.0N, 2.0W\n\n' "$place"
        done ;;
      "relay set") echo "$4" > /tmp/mullvad-country; echo "set $4" >> /tmp/mullvad.log ;;
      "connect "*) touch /tmp/mullvad-on ;;
      "disconnect "*) rm -f /tmp/mullvad-on ;;
    esac
  '';
  shotPath = lib.makeBinPath ([ fakeSlurp ] ++ quietShell.runtime) + ":/run/current-system/sw/bin";
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
      # Stands in for the password prompt: the test session has no polkit agent.
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.timedate1.set-timezone" && subject.user == "user")
            return polkit.Result.YES;
        });
      '';
      services.pipewire = {
        enable = true;
        # The VM has no sound card; app streams need a sink to play into.
        extraConfig.pipewire."10-null-sink"."context.objects" = [
          {
            factory = "adapter";
            args = {
              "factory.name" = "support.null-audio-sink";
              "node.name" = "smoke-sink";
              "media.class" = "Audio/Sink";
              "audio.position" = "FL,FR";
            };
          }
        ];
      };
      environment.systemPackages = [
        pkgs.foot
        # Its icon for the fake tray item, and with Neovim the notes window.
        pkgs.kitty
        pkgs.neovim
        quietShell
        fakeMullvad
      ];
    };

    testScript = ''
      import json
      from datetime import timedelta

      def session(cmd):
          if cmd.startswith("quiet-shell-ipc"):
              # A call can find the shell momentarily busy under software
              # rendering; one that keeps failing still fails the test.
              try:
                  return machine.wait_until_succeeds(f"su user -c '${inSession} {cmd}'", timeout=timedelta(seconds=5))
              except BaseException:
                  print("IPC failed:", machine.execute(f"su user -c '${inSession} {cmd}' 2>&1")[1])
                  print(machine.execute("tail -n 25 /tmp/shell.log")[1])
                  raise
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
          # A stalled VM can deliver a key's release late, and the letter then repeats.
          session("hyprctl eval \"hl.config({ input = { repeat_rate = 0 } })\"")

      def start_shell():
          # Qt hides a window whose frame callback takes over 100 ms, then redraws it
          # when the callback arrives. Software compositing on a slow VM takes longer
          # than that every frame, so each redraw would cause the next one forever.
          machine.succeed("su user -c '${inSession} env QT_WAYLAND_FRAME_CALLBACK_TIMEOUT=5000 setsid quiet-shell > /tmp/shell.log 2>&1 &'")
          machine.wait_until_succeeds("su user -c '${inSession} quiet-shell-ipc state' | grep -q panel", timeout=timedelta(seconds=90))

      with subtest("the shell starts and answers IPC"):
          # The tray's registry runs first and apart, as its user unit does.
          session("setsid ${quietShell.trayWatcher}/bin/quiet-tray-watcher > /tmp/watcher.log 2>&1 &")
          machine.wait_until_succeeds("su user -c '${inSession} busctl --user status org.kde.StatusNotifierWatcher'", timeout=timedelta(seconds=30))
          start_shell()
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
          # 3 picks Screen, the third option, and the picture lands at once.
          machine.send_key("3")
          machine.wait_until_succeeds("ls /home/user/.local/share/pictures/Screenshots/*.png", timeout=timedelta(seconds=20))
          retry(lambda _: not state()["screenshot"], timeout=timedelta(seconds=5))

      with subtest("a dragged area is captured at its size"):
          machine.succeed("rm /home/user/.local/share/pictures/Screenshots/*.png")
          session('quiet-shell-ipc captureArea "10,20 200x100"')
          machine.wait_until_succeeds("ls /home/user/.local/share/pictures/Screenshots/*.png", timeout=timedelta(seconds=20))
          header = machine.succeed("od -An -tx1 -j16 -N8 /home/user/.local/share/pictures/Screenshots/*.png").split()
          size = (int("".join(header[:4]), 16), int("".join(header[4:]), 16))
          assert size == (200, 100), f"the area came out {size}"

      with subtest("the control centre drives the player from the keyboard"):
          # A stand-in Spotify on MPRIS, which the shell watches instead of polling.
          session("setsid ${dbusPython}/bin/python3 ${../quiet-shell/fakes/player.py} /tmp/player.log >/dev/null 2>&1 &")
          session("quiet-shell-ipc controls")
          wait_for(lambda s: s["panel"] == "controls" and s["media"] and s["media"]["playing"], "now-playing")
          # Dvorak again: J and K sit on the QWERTY c and v keys.
          for key in ("spc", "c", "v"):
              machine.send_key(key)
          machine.wait_until_succeeds("test $(wc -l < /tmp/player.log) -ge 3", timeout=timedelta(seconds=10))
          sent = machine.succeed("cat /tmp/player.log").split()
          # Space while playing asks for a pause outright.
          assert sent == ["pause", "next", "previous"], sent
          # The pause shows without waiting for a poll.
          retry(lambda _: not state()["media"]["playing"], timeout=timedelta(seconds=5))
          session("quiet-shell-ipc close")

      with subtest("a track change never shows Not playing"):
          session("quiet-shell-ipc controls")
          wait_for(lambda s: s["panel"] == "controls" and s["media"], "cover-before-skip")
          before = state()["media"]["title"]
          machine.send_key("c")
          seen = []
          def changed(_):
              media = state()["media"]
              seen.append(media and media["title"])
              return seen[-1] not in (None, before)
          try:
              retry(changed, timeout=timedelta(seconds=10))
          except Exception:
              pass
          assert None not in seen, f"the card went blank between tracks: {seen}"
          assert seen and seen[-1] != before, f"the track never changed: {seen}"
          machine.sleep(timedelta(seconds=2))
          machine.screenshot("cover-after-skip")
          session("quiet-shell-ipc close")

      with subtest("sound details list each playing app"):
          machine.succeed(
              "su user -c '${inSession} setsid pw-cat --playback --raw --format s16 --rate 48000 --channels 2"
              " -P \"{ application.name = SmokeTone }\" /dev/zero > /tmp/tone.log 2>&1 &'"
          )
          status, _ = machine.execute("for _ in $(seq 30); do su user -c '${inSession} pw-dump' | grep -q SmokeTone && exit 0; sleep 1; done; exit 1")
          if status != 0:
              print(machine.execute("cat /tmp/tone.log; su user -c '${inSession} systemctl --user status pipewire wireplumber' | head -30")[1])
              raise AssertionError("test stream never appeared")
          session("quiet-shell-ipc detail sound")
          wait_for(lambda s: s["detail"] == "sound" and "SmokeTone" in s["streams"], "sound-apps")
          session("quiet-shell-ipc close")

      with subtest("text capture reads the words on screen"):
          session("quiet-shell-ipc shortcuts")
          wait_for(lambda s: s["cheatSheet"], "text-source")
          # One session for both: wl-copy serves the clipboard from a child that a
          # finishing su session would take with it.
          session(
              "env PATH=${shotPath} sh -c \"python3 ${quietShell}/share/quiet-shell/scripts/screenshot.py text"
              " > /tmp/ocr.json && sleep 1 && wl-paste > /tmp/pasted.txt\""
          )
          text = json.loads(machine.succeed("cat /tmp/ocr.json"))["text"]
          # The moving wallpaper shows through, so OCR varies a little run to run.
          labels = ["Maximise", "Fullscreen", "Focus left", "Focus right", "Overview", "Notifications", "Lock", "Browser"]
          found = [label for label in labels if label in text]
          assert len(found) >= 5, f"OCR read only {found} from the sheet: {text!r}"
          assert machine.succeed("cat /tmp/pasted.txt").strip() == text, "OCR text was not copied"
          session("quiet-shell-ipc close")

      with subtest("window previews render a real window"):
          session("setsid foot --title=preview-source sh -c \"seq 1 400 | column -c 180; sleep infinity\" >/dev/null 2>&1 &")
          machine.wait_until_succeeds("su user -c '${inSession} hyprctl clients' | grep -q preview-source", timeout=timedelta(seconds=30))
          session("quiet-shell-ipc overview")
          wait_for(lambda s: s["overview"], "overview-window")
          session("quiet-shell-ipc close")
          # Let the previews finish fading out first. Closing a window while its
          # preview is mid-capture can end the shell's Wayland connection with
          # "invalid object": the compositor drops the capture frame itself.
          retry(lambda _: not state()["overview"], timeout=timedelta(seconds=10))
          machine.sleep(timedelta(seconds=2))
          machine.succeed("pkill -u user -x foot")
          machine.wait_until_fails("su user -c '${inSession} hyprctl clients' | grep -q preview-source", timeout=timedelta(seconds=10))

      with subtest("the calendar moves with Vim keys"):
          def screen_text():
              session(
                  "env PATH=${shotPath} sh -c \"python3 ${quietShell}/share/quiet-shell/scripts/screenshot.py text > /tmp/cal.json\""
              )
              return json.loads(machine.succeed("cat /tmp/cal.json"))["text"]

          session("quiet-shell-ipc notifications")
          wait_for(lambda s: s["panel"] == "notifications", "calendar")
          # Dvorak on QWERTY scancodes: l is the p key. l moves a day, L a month.
          machine.send_key("p")
          tomorrow = machine.succeed("date -d tomorrow '+%A %-d %B'").strip()
          retry(lambda _: tomorrow in screen_text(), timeout=timedelta(seconds=15))
          machine.send_key("shift-p")
          next_month = machine.succeed("date -d \"$(date -d tomorrow +%Y-%m-01) +1 month\" +%B").strip()
          retry(lambda _: next_month in screen_text(), timeout=timedelta(seconds=15))
          machine.screenshot("calendar-next-month")
          session("quiet-shell-ipc close")

      with subtest("Spotlight sets the location, and with it the time zone"):
          machine.succeed("timedatectl set-timezone Europe/London")
          # Type literally: switch the Dvorak layout to plain US while typing.
          session("hyprctl eval \"hl.config({ input = { kb_variant = [[]] } })\"")
          def typed(want):
              seen = []
              def check(_):
                  seen.append(state()["query"])
                  return seen[-1] == want
              try:
                  retry(check, timeout=timedelta(seconds=10))
              except Exception:
                  raise AssertionError(f"Spotlight got {seen[-1]!r}, not {want!r}")

          # The real key: Hyprland reaches the shell directly, without a process.
          machine.send_key("meta_l-spc")
          wait_for(lambda s: s["spotlight"], "spotlight-empty")
          machine.send_chars("location norway")
          typed("location norway")
          # A country lists its biggest towns.
          retry(lambda _: "Location: Oslo" in state()["results"], timeout=timedelta(seconds=10))
          # Ctrl+Backspace drops the word, and the very next letter still arrives.
          machine.send_key("ctrl-backspace")
          machine.send_chars("warsaw")
          typed("location warsaw")
          retry(lambda _: state()["results"][:1] == ["Location: Warsaw"], timeout=timedelta(seconds=10))
          machine.sleep(timedelta(seconds=2))
          machine.screenshot("spotlight-timezone")
          machine.send_key("ret")
          machine.wait_until_succeeds("readlink /etc/localtime | grep -q Europe/Warsaw", timeout=timedelta(seconds=20))
          # Once the shell sees the new zone, its clock shows Warsaw's time at once,
          # not at the next minute or the next restart.
          retry(lambda _: state()["sys"].get("timezone") == "Europe/Warsaw", timeout=timedelta(seconds=20))
          clocks = []
          def caught_up(_):
              now = state()
              clocks.append((now["clock"], machine.succeed("date +%H:%M").strip(), now["sys"].get("utcOffset")))
              return clocks[-1][0] == clocks[-1][1]
          try:
              retry(caught_up, timeout=timedelta(seconds=2))
          except Exception:
              raise AssertionError(f"the clock lagged the zone (shell, system, offset): {clocks}")
          print(f"clock caught up after {len(clocks)} checks: {clocks[-1]}")
          retry(lambda _: state()["sys"]["timezone"] == "Europe/Warsaw" and not state()["writes"], timeout=timedelta(seconds=20))
          retry(lambda _: (state()["place"] or {}).get("name") == "Warsaw", timeout=timedelta(seconds=10))
          chosen = json.loads(machine.succeed("cat /home/user/.local/state/quiet-shell/location.json"))
          assert chosen["zone"] == "Europe/Warsaw" and round(chosen["lat"]) == 52, chosen
          session("hyprctl eval \"hl.config({ input = { kb_variant = [[dvorak]] } })\"")

      with subtest("Mullvad answers to letters, Vim keys and Spotlight"):
          session("hyprctl eval \"hl.config({ input = { kb_variant = [[]] } })\"")
          def relay():
              return machine.succeed("cat /tmp/mullvad-country 2>/dev/null || echo se").strip()
          def settled():
              return not state()["writes"]

          session("quiet-shell-ipc controls")
          retry(lambda _: state()["panel"] == "controls", timeout=timedelta(seconds=10))
          machine.sleep(timedelta(seconds=2))
          machine.send_key("v")
          wait_for(lambda s: s["detail"] == "vpn", "vpn-key-hints")
          machine.send_key("m")
          machine.wait_until_succeeds("test -e /tmp/mullvad-on", timeout=timedelta(seconds=10))
          retry(lambda _: settled(), timeout=timedelta(seconds=15))
          machine.send_key("l")
          wait_for(lambda s: s["detail"] == "mullvad" and s["countries"] == ["al", "se", "gb"], "mullvad-unused-order")
          # k stops at the top, so this ends on the third row.
          for letter in ("k", "j", "j", "k", "j"):
              machine.send_key(letter)
          machine.sleep(timedelta(seconds=1))
          machine.screenshot("mullvad-cursor")
          machine.send_key("ret")
          machine.wait_until_succeeds("grep -qx 'set gb' /tmp/mullvad.log", timeout=timedelta(seconds=10))
          retry(lambda _: settled(), timeout=timedelta(seconds=15))
          assert state()["countries"] == ["al", "se", "gb"], "rows moved under the cursor"
          machine.send_key("esc")
          retry(lambda _: state()["detail"] == "vpn", timeout=timedelta(seconds=10))
          machine.sleep(timedelta(seconds=1))
          machine.send_key("l")
          wait_for(lambda s: s["detail"] == "mullvad" and s["countries"] == ["gb", "al", "se"], "mullvad-recent-order")
          # The cursor is back on the top row, the country already in use.
          machine.send_key("ret")
          machine.sleep(timedelta(seconds=2))
          sets = machine.succeed("cat /tmp/mullvad.log").split("\n")
          assert sets.count("set gb") == 1, f"picking the current country reconnected: {sets}"
          session("quiet-shell-ipc close")
          retry(lambda _: state()["panel"] == "", timeout=timedelta(seconds=10))

          machine.send_key("meta_l-spc")
          wait_for(lambda s: s["spotlight"], "spotlight-mullvad-empty")
          machine.send_chars("mullvad britain")
          typed("mullvad britain")
          retry(lambda _: state()["results"][:1] == ["Mullvad: UK"], timeout=timedelta(seconds=10))
          machine.send_key("ctrl-backspace")
          machine.send_chars("alb")
          typed("mullvad alb")
          retry(lambda _: state()["results"][:1] == ["Mullvad: Albania"], timeout=timedelta(seconds=10))
          machine.send_key("ret")
          retry(lambda _: relay() == "al", timeout=timedelta(seconds=10))
          retry(lambda _: settled(), timeout=timedelta(seconds=15))
          retry(lambda _: not state()["spotlight"], timeout=timedelta(seconds=10))
          machine.sleep(timedelta(seconds=1))
          machine.send_key("meta_l-spc")
          wait_for(lambda s: s["spotlight"], "spotlight-mullvad-switch")
          machine.send_chars("mullvad")
          typed("mullvad")
          retry(lambda _: any(r.endswith(": Mullvad") for r in state()["results"]), timeout=timedelta(seconds=10))
          machine.send_key("ret")
          machine.wait_until_succeeds("test ! -e /tmp/mullvad-on", timeout=timedelta(seconds=10))
          retry(lambda _: settled(), timeout=timedelta(seconds=15))
          session("hyprctl eval \"hl.config({ input = { kb_variant = [[dvorak]] } })\"")

      with subtest("Letters open the menus, and j, k, h and l work inside them"):
          session("hyprctl eval \"hl.config({ input = { kb_variant = [[]] } })\"")
          def sink():
              return state()["sys"]["sink"]["level"]
          def stream_volume():
              nodes = json.loads(session("pw-dump"))
              return next(n["info"]["params"]["Props"][0]["channelVolumes"] for n in nodes
                          if n.get("type", "").endswith("Node") and (n.get("info") or {}).get("props", {}).get("application.name") == "SmokeTone")

          session("quiet-shell-ipc controls")
          retry(lambda _: state()["panel"] == "controls", timeout=timedelta(seconds=10))
          machine.sleep(timedelta(seconds=2))
          retry(lambda _: sink() > 0, timeout=timedelta(seconds=10))
          before = sink()
          machine.send_key("h")
          machine.send_key("h")
          machine.send_key("l")
          retry(lambda _: sink() == before - 5, timeout=timedelta(seconds=15))
          machine.send_key("u")
          wait_for(lambda s: s["detail"] == "bluetooth", "bluetooth-from-letter")
          machine.send_key("esc")
          retry(lambda _: state()["detail"] == "", timeout=timedelta(seconds=10))
          machine.sleep(timedelta(seconds=1))
          machine.send_key("o")
          wait_for(lambda s: s["detail"] == "sound" and "SmokeTone" in s["streams"], "sound-from-letter")
          # The output, then the app's slider, which can't go past the end of the list.
          for letter in ("j", "j"):
              machine.send_key(letter)
          retry(lambda _: state()["cursor"].startswith("stream "), timeout=timedelta(seconds=10))
          machine.sleep(timedelta(seconds=1))
          machine.screenshot("sound-slider-cursor")
          loud = stream_volume()
          machine.send_key("h")
          retry(lambda _: stream_volume() != loud, timeout=timedelta(seconds=10))
          machine.send_key("esc")
          retry(lambda _: state()["detail"] == "", timeout=timedelta(seconds=10))
          machine.sleep(timedelta(seconds=1))
          machine.send_key("t")
          wait_for(lambda s: s["detail"] == "theme", "theme-from-letter")
          assert state()["cursor"] == "", "the cursor outlived its menu"
          # Enter means nothing until j has picked a row.
          machine.send_key("ret")
          machine.sleep(timedelta(seconds=1))
          assert "theme" not in state()["writes"], "Enter acted with no row picked"
          machine.send_key("j")
          retry(lambda _: state()["cursor"] != "", timeout=timedelta(seconds=10))
          machine.sleep(timedelta(seconds=1))
          machine.screenshot("theme-cursor")
          machine.send_key("ret")
          retry(lambda _: "theme" in state()["writes"], timeout=timedelta(seconds=10))
          session("quiet-shell-ipc close")
          session("hyprctl eval \"hl.config({ input = { kb_variant = [[dvorak]] } })\"")

      with subtest("notes open once, float, and show in the overview"):
          machine.succeed("install -d -o user /home/user/.local/share/quiet-shell && printf '# Ideas\\nanki generator\\npersonal dashboard\\n' > /home/user/.local/share/quiet-shell/notes.md && chown user /home/user/.local/share/quiet-shell/notes.md")
          session("quiet-shell-ipc overview")
          wait_for(lambda s: s["overview"], "overview-notes")
          session("quiet-shell-ipc close")

          def notes_windows():
              clients = json.loads(session("hyprctl -j clients"))
              return [c for c in clients if c["class"] == "quiet-notes"]

          session("quiet-shell-ipc notes")
          retry(lambda _: len(notes_windows()) == 1, timeout=timedelta(seconds=30))
          assert notes_windows()[0]["floating"], notes_windows()
          machine.sleep(timedelta(seconds=2))
          machine.screenshot("notes-window")
          # Asking again focuses the open pad rather than starting another.
          session("quiet-shell-ipc notes")
          machine.sleep(timedelta(seconds=3))
          assert len(notes_windows()) == 1, notes_windows()
          machine.succeed("pkill -u user -x .kitty-wrapped")
          retry(lambda _: not notes_windows(), timeout=timedelta(seconds=10))

      with subtest("tray icons are grey until pointed at, and outlive a shell restart"):
          session("setsid ${dbusPython}/bin/python3 ${../quiet-shell/fakes/tray.py} /tmp/tray.log >/dev/null 2>&1 &")
          session("quiet-shell-ipc pin")
          wait_for(lambda s: "quiet-test" in s["tray"] and s["top"], "tray-grey")
          session("quiet-shell-ipc pin")
          # The registry isn't the shell's, so the icon stays registered while the
          # shell restarts. The fake app registers once, so the new shell can only
          # show it by finding it in the registry.
          owner = session("busctl --user status org.kde.StatusNotifierWatcher | grep '^Comm='")
          assert "quickshell" not in owner, f"the shell owns the tray registry: {owner}"
          machine.succeed("pkill -u user -f -- '-p /nix/store/[^ ]*-quiet-shell'")
          machine.wait_until_fails("pgrep -u user -f -- '-p /nix/store/[^ ]*-quiet-shell'", timeout=timedelta(seconds=10))
          start_shell()
          retry(lambda _: "quiet-test" in state()["tray"], timeout=timedelta(seconds=20))
          machine.succeed("pkill -u user -f fakes/tray.py || pkill -u user -f tray.py")

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

      with subtest("the power menu works from the keyboard"):
          # Dvorak on QWERTY scancodes: r is the o key and o is s.
          machine.send_key("meta_l-esc")
          wait_for(lambda s: s["panel"] == "system", "power-menu")
          machine.send_key("o")
          wait_for(lambda s: s["confirm"] == "Restart", "power-confirm")
          # Only Enter confirms: the letter again leaves the question open.
          machine.send_key("o")
          machine.sleep(timedelta(seconds=1))
          assert state()["confirm"] == "Restart", "pressing R twice confirmed the restart"
          machine.send_key("esc")
          retry(lambda _: state()["confirm"] == "", timeout=timedelta(seconds=10))
          # Log Out is the one action the VM survives: confirm it and the session ends.
          hyprland = machine.succeed("pgrep -u user -x .Hyprland-wrapp || pgrep -u user -f 'Hyprland --watchdog'").split()[0]
          machine.send_key("meta_l-esc")
          retry(lambda _: state()["panel"] == "system", timeout=timedelta(seconds=10))
          # The menu takes the keyboard a moment after it opens; slow under software
          # rendering, so let it settle before typing.
          machine.sleep(timedelta(seconds=1))
          machine.send_key("s")
          retry(lambda _: state()["confirm"] == "Log Out", timeout=timedelta(seconds=10))
          machine.send_key("ret")
          machine.wait_until_fails(f"kill -0 {hyprland}", timeout=timedelta(seconds=20))
    '';
  }
