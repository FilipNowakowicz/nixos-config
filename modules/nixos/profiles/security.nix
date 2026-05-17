{ config, lib, ... }:
let
  sshEnabled = config.services.openssh.enable;
  fail2ban = config.services.fail2ban;
  globallyOpenRemoteAccessPorts =
    lib.filter (port: builtins.elem port (config.networking.firewall.allowedTCPPorts or [ ]))
      [
        22
        443
      ];
  fail2banViolations = lib.filter (msg: msg != "") [
    (lib.optionalString (!fail2ban.enable) "services.fail2ban.enable must be true")
    (lib.optionalString (fail2ban.maxretry > 3) "services.fail2ban.maxretry must be <= 3")
    (lib.optionalString (fail2ban.bantime != "30m") ''services.fail2ban.bantime must be "30m"'')
    (lib.optionalString (
      !fail2ban."bantime-increment".enable
    ) "services.fail2ban.bantime-increment.enable must be true")
    (lib.optionalString (
      fail2ban."bantime-increment".maxtime == null
    ) "services.fail2ban.bantime-increment.maxtime must be set")
  ];
in
{
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
      assertion = !sshEnabled || fail2banViolations == [ ];
      message = "OpenSSH hosts must keep fail2ban hardened: ${lib.concatStringsSep "; " fail2banViolations}";
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
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.default.accept_source_route" = 0;
  };
}
