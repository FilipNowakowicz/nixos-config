{
  config,
  lib,
  pkgs,
  ...
}:
let
  # See restic-wait-repo.nix for why both units probe B2 before starting.
  waitForRepo =
    unit:
    import ./restic-wait-repo.nix { inherit pkgs; } {
      inherit unit;
      repositoryFile = config.sops.secrets.restic_repository.path;
    };

  # anki-generator's docs/recovery.md forbids copying its live SQLite file.
  # Take a consistent copy through SQLite's backup API, as the user so no
  # root-owned journal appears beside it, and swap it in only once
  # integrity_check passes. A failure leaves the previous snapshot in place
  # and warns instead of failing the whole workstation backup.
  ankiLocal = "/home/user/academic/anki-generator/local";
  ankiSnapshotDir = "${ankiLocal}/restic-snapshot";
  ankiSnapshot = pkgs.writeShellScript "anki-generator-snapshot" ''
    db=${ankiLocal}/workspace/state.sqlite3
    [ -e "$db" ] || exit 0
    if ! ${pkgs.util-linux}/bin/setpriv --reuid=user --regid=users --init-groups -- ${pkgs.writeShellScript "anki-generator-snapshot-user" ''
      set -eu
      sqlite=${pkgs.sqlite}/bin/sqlite3
      ${pkgs.coreutils}/bin/install -d -m 0700 ${ankiSnapshotDir}
      tmp=${ankiSnapshotDir}/state.sqlite3.tmp
      ${pkgs.coreutils}/bin/rm -f "$tmp"
      "$sqlite" -readonly ${ankiLocal}/workspace/state.sqlite3 ".backup '$tmp'"
      [ "$("$sqlite" -readonly "$tmp" 'PRAGMA integrity_check;')" = ok ]
      ${pkgs.coreutils}/bin/mv -f "$tmp" ${ankiSnapshotDir}/state.sqlite3
    ''}; then
      echo "anki-generator-snapshot: snapshot failed; backing up the previous one" >&2
    fi
  '';
in
{
  # Hidden maintenance mount for the filesystem top-level. btrbk snapshots
  # subvolumes by their real top-level names (`@home`, `@persist`) rather than
  # via nested mount paths.
  fileSystems."/.btrfs-root" = {
    device = "/dev/disk/by-label/main-root";
    fsType = "btrfs";
    options = [
      "subvol=/"
      "noatime"
      "discard=async"
    ];
  };

  services = {
    btrbk.instances.local = {
      onCalendar = "daily";
      snapshotOnly = true;
      settings = {
        snapshot_preserve_min = "2d";
        snapshot_preserve = "14d";
        volume."/.btrfs-root" = {
          snapshot_dir = ".snapshots";
          subvolume = {
            "@home" = { };
            "@persist" = { };
          };
        };
      };
    };

    restic.backups.local = {
      paths = [
        "/home/user/.ssh"
        "/home/user/.gnupg"
        "/home/user/nix"
        "/home/user/.mozilla/firefox"
        "/home/user/.config/mozilla/firefox"
        "/home/user/.config/spotify"
        "/home/user/.config/discord"
        "/home/user/.config/gh"
        "/home/user/.config/gcloud"
        "/home/user/.local/share/Anki2"
        "/home/user/.config/chromium"
        "/home/user/.local/share/kwalletd"
        "/home/user/.codex"
        "/home/user/.claude"
        "/home/user/.claude.json"
        "/home/user/.local/share/quiet-shell/notes.md" # quick notes (SUPER+SHIFT+N)
        "/home/user/.config/sops"
        "/etc/machine-id"
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
        "/etc/NetworkManager/system-connections"
        "/etc/mullvad-vpn"
        "/var/lib/tailscale"
        "/var/lib/bluetooth"
        "/var/lib/fprint"
        "/var/lib/tudor"
        "/var/lib/sbctl"
        "/var/lib/usbguard"
        # Project work that exists only on this laptop. Tracked code is on
        # GitHub and linked worktrees are temporary, so neither is listed.
        "/home/user/trading/secrets" # gitignored credentials
        # Research outputs; the downloaded market data beside them is refetchable.
        "/home/user/trading/data/s004"
        "/home/user/trading/data/s004-effort"
        "/home/user/trading/data/astra"
        # anki-generator's card database lives outside Git (its docs/recovery.md).
        # Its workspace minus the live database, which ankiSnapshot copies safely.
        "${ankiLocal}/workspace"
        "${ankiLocal}/paths.json"
        "${ankiLocal}/anki-courses.json"
        "${ankiSnapshotDir}"
        # VM images are deliberately not backed up. Whonix (/var/lib/libvirt)
        # and the user-session Kali VM (~/.local/share/kali-vm) are
        # near-default images that can be re-downloaded upstream; their qcow2
        # disks were most of this repo's B2 usage. Both persist locally only.
      ];
      exclude = [
        # Token/credential caches — not durable; regenerated on next gcloud auth
        "/home/user/.config/gcloud/access_tokens.db"
        "/home/user/.config/gcloud/credentials.db"
        "/home/user/.config/gcloud/logs"
        "/home/user/.config/gcloud/legacy_credentials"
        # The app's own rotating copies; restic history replaces them.
        "${ankiLocal}/workspace/backups"
        # Never read the live database; the verified snapshot stands in for it.
        "${ankiLocal}/workspace/state.sqlite3*"
      ];
      backupPrepareCommand = "${ankiSnapshot}";
    };
  };

  systemd = {
    services = {
      restic-backups-local.serviceConfig = {
        # Runs before the restic module's own pre-start, which opens the repo
        # and fails hard on the first DNS error. Inherits the module's
        # EnvironmentFile (B2 creds) and RESTIC_PASSWORD_FILE.
        ExecStartPre = lib.mkBefore [ (waitForRepo "restic-backups-local") ];
      };

      btrbk-local-snapshot-dir = {
        description = "Ensure btrbk local snapshot directory exists";
        requiredBy = [ "btrbk-local.service" ];
        before = [ "btrbk-local.service" ];
        unitConfig.RequiresMountsFor = "/.btrfs-root";
        serviceConfig.Type = "oneshot";
        script = ''
          ${pkgs.coreutils}/bin/install -d -m 0750 -o btrbk -g btrbk /.btrfs-root/.snapshots
        '';
      };

      restic-check-local = {
        description = "Restic workstation repository integrity check";
        # See waitForRepo above for why this probes B2 instead of relying on
        # network-online.target. The rest comes from profiles/backup.nix.
        serviceConfig.ExecStartPre = waitForRepo "restic-check-local";
      };
    };
  };
}
