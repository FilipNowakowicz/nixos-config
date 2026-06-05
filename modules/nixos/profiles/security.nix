{
  config,
  lib,
  pkgs,
  ...
}:
let
  invariants = import ../../../lib/invariants.nix { inherit lib pkgs; };
  sshEnabled = config.services.openssh.enable;
  globallyOpenRemoteAccessPorts =
    lib.filter (port: builtins.elem port (config.networking.firewall.allowedTCPPorts or [ ]))
      [
        22
        443
      ];
  fail2banCheck = invariants.checkHardenedFail2ban config;
in
{
  # ── Coredumps ──────────────────────────────────────────────────────────
  systemd.coredump.settings.Coredump = {
    Storage = "journal";
    Compress = true;
    ProcessSizeMax = "512M";
    MaxUse = "1G";
  };

  # ── Firewall ───────────────────────────────────────────────────────────
  networking.firewall.enable = true;
  networking.nftables.enable = true;

  # ── SSH ────────────────────────────────────────────────────────────────
  services.openssh = {
    enable = lib.mkDefault false;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # ── Intrusion Prevention ───────────────────────────────────────────────
  services.fail2ban = {
    enable = true;
    maxretry = 3;
    bantime = "30m";
    "bantime-increment" = {
      enable = true;
      maxtime = "24h";
      overalljails = true;
    };
  };

  assertions = [
    {
      assertion = !sshEnabled || fail2banCheck.passed;
      message = "OpenSSH hosts must keep fail2ban hardened: ${fail2banCheck.message}";
    }
  ];

  warnings =
    lib.optional (sshEnabled && config.services.openssh.openFirewall)
      "OpenSSH is enabled with services.openssh.openFirewall = true; prefer explicit interface-scoped firewall rules unless this host intentionally exposes SSH."
    ++
      lib.optional (config.services.tailscale.enable && globallyOpenRemoteAccessPorts != [ ])
        "Tailscale-enabled host has globally open remote-access ports (${lib.concatStringsSep ", " (map builtins.toString globallyOpenRemoteAccessPorts)}); prefer interface-scoped firewall rules unless this host intentionally exposes them.";

  # ── Kernel Hardening ───────────────────────────────────────────────────
  boot.kernel.sysctl = {
    "kernel.unprivileged_bpf_disabled" = 1;
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.yama.ptrace_scope" = 1;
    "net.core.bpf_jit_harden" = 2;
    "kernel.kexec_load_disabled" = 1;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.default.accept_source_route" = 0;
  };
}
