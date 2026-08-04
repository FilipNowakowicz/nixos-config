_: {
  # Boot-selectable mode for anonymous/security-lab work. This hardens the host
  # and removes daily-desktop network identity emitters, while keeping Tor
  # workflows inside Whonix rather than pretending every host tool is anonymous.
  specialisation.anonymous.configuration =
    {
      config,
      lib,
      ...
    }:
    {
      system.nixos.tags = [ "anonymous" ];

      # Amnesic home: shadow the persistent @home with a tmpfs so every
      # anonymous boot starts with no logins, cookies, shell history, or scan
      # artifacts. Home Manager repopulates declarative dotfiles from the Nix
      # store on boot (home-manager-user.service), so the configured
      # environment survives while session data does not. The real @home is
      # not wiped, only hidden while this specialisation is booted.
      # NOTE: uid/gid assume `user` is 1000:users(100) — the first normal user,
      # stable via /var/lib/nixos. If Home Manager activation fails on a fresh
      # boot with permission errors, verify this assumption first.
      fileSystems."/home/user" = {
        device = "none";
        fsType = "tmpfs";
        options = [
          "mode=0700"
          "uid=1000"
          "gid=100"
        ];
      };

      # Fresh machine-id each anonymous boot: drop it from the persisted file
      # set so systemd regenerates a transient random one on the ephemeral
      # root. The SSH host key stays persisted (sops reads it directly from
      # /persist; OpenSSH itself is disabled in this spec). Scoped to the
      # specialisation — the normal boot keeps its stable machine-id.
      environment.persistence."/persist" = {
        files = lib.mkForce [
          "/etc/ssh/ssh_host_ed25519_key"
          "/etc/ssh/ssh_host_ed25519_key.pub"
        ];
        # Amnesic: do not bind-mount persistent identity state from /persist
        # while booted anonymously. The default boot persists tailnet node
        # identity, saved Wi-Fi/VPN profiles, Bluetooth pairings, fingerprint
        # enrolments, USBGuard rule hashes, Mullvad account/device state, etc.;
        # leaving those mounted here would tie an anonymous session back to the
        # daily-desktop identity and undercut the amnesic claim. Keep only what
        # boot/UX needs and nothing that reveals who or where this host is.
        #   - /var/lib/nixos: stable uid/gid for the tmpfs-home uid=1000 assumption
        #   - backlight/rfkill: brightness + radio-block UX state, identity-free
        # /var/log is intentionally dropped too (no persistent logs while amnesic).
        # /var/lib/libvirt is NOT mounted here: the Whonix images live in
        # /persist and are only relevant when the operator explicitly starts the
        # VMs (Whonix provides its own anonymity surface), so they stay out of
        # the default anonymous mount set.
        directories = lib.mkForce [
          "/var/lib/nixos"
          "/var/lib/systemd/backlight"
          "/var/lib/systemd/rfkill"
        ];
      };

      networking = {
        hostName = lib.mkForce "nixos";
        domain = lib.mkForce "";
        firewall = {
          checkReversePath = lib.mkForce "strict";
          interfaces.tailscale0 = lib.mkForce { };
        };
        networkmanager = {
          wifi = {
            scanRandMacAddress = true;
            macAddress = "random";
          };
          ethernet.macAddress = "random";
        };
      };

      hardware.bluetooth = {
        enable = lib.mkForce false;
        powerOnBoot = lib.mkForce false;
      };

      services = {
        blueman.enable = lib.mkForce false;
        fprintd.enable = lib.mkForce false;
        fwupd.enable = lib.mkForce false;
        openssh.enable = lib.mkForce false;
        sunshine.enable = lib.mkForce false;
        tailscale.enable = lib.mkForce false;

        prometheus.enable = lib.mkForce false;
        prometheus.exporters.node.enable = lib.mkForce false;
        alloy.enable = lib.mkForce false;
        opentelemetry-collector.enable = lib.mkForce false;

        tor = {
          enable = true;
          client.enable = true;
        };
      };

      # Route proxychained tools through the Tor SOCKS port. Without an
      # explicit proxy the generated [ProxyList] is empty and `proxychains`
      # silently connects direct, defeating the point. SOCKS carries TCP
      # connect() only: use this for OSINT/recon TCP tools, NOT SYN/UDP/raw
      # scans (nmap -sS, masscan, ping sweeps bypass SOCKS entirely). Active
      # pentest scanning should exit via Mullvad, which hides the origin IP
      # with full protocol support; Tor is for low-volume, origin-sensitive
      # lookups and browsing (the latter belongs in Whonix).
      programs.proxychains = {
        enable = true;
        proxies.tor = {
          enable = true;
          type = "socks5";
          host = "127.0.0.1";
          port = 9050;
        };
      };

      security.apparmor.enable = true;

      boot.kernel.sysctl = {
        # kernel.dmesg_restrict, kernel.kptr_restrict, and
        # kernel.yama.ptrace_scope are inherited from profiles/security.nix.
        "kernel.perf_event_paranoid" = 3;
        "dev.tty.ldisc_autoload" = 0;
        "net.ipv4.tcp_syncookies" = 1;
      };

      systemd = {
        user.services.sunshine.enable = lib.mkForce false;
        services = {
          bluetooth-load-btusb = {
            enable = lib.mkForce false;
            requiredBy = lib.mkForce [ ];
          };
          bluetooth-power-on = {
            enable = lib.mkForce false;
            wantedBy = lib.mkForce [ ];
          };
          tailscale-bypass-routing = {
            enable = lib.mkForce false;
            wantedBy = lib.mkForce [ ];
          };
          restic-backups-local.enable = lib.mkForce false;
          restic-check-local.enable = lib.mkForce false;
          btrbk-local.enable = lib.mkForce false;
          btrbk-local-snapshot-dir.enable = lib.mkForce false;
          mullvad-daemon.postStart = lib.mkForce "";
          # Base mullvad-lockdown already sets lockdown-mode on; only add auto-connect.
          mullvad-anonymous-mode = {
            description = "Enable Mullvad auto-connect in anonymous mode";
            after = [ "mullvad-lockdown.service" ];
            bindsTo = [ "mullvad-daemon.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              ${config.services.mullvad-vpn.package}/bin/mullvad auto-connect set on
              # auto-connect only fires on daemon start; the daemon is already
              # running this boot, so kick an explicit connect. Best effort —
              # lockdown mode (set by mullvad-lockdown) keeps traffic
              # fail-closed regardless of whether this succeeds.
              ${config.services.mullvad-vpn.package}/bin/mullvad connect || true
            '';
          };
        };
        timers = {
          restic-backups-local.enable = lib.mkForce false;
          restic-check-local.enable = lib.mkForce false;
          btrbk-local.enable = lib.mkForce false;
        };
      };
    };
}
