# Lynis-guided hardening, scoped to this headless GCP server so the dev
# machines (main/mac) stay unencumbered. Extends the shared
# modules/nixos/profiles/security.nix rather than replacing it.
#
# Deliberately NOT touched, to avoid breaking things:
#   - net.*.rp_filter / ip_forward — left to Tailscale's routing.
#   - kernel.modules_disabled — would block all module loading.
#   - SSH local forwarding — kept so the Grafana break-glass tunnel
#     (ssh -L 3000:127.0.0.1:3000 …) still works.
#   - password aging — no interactive password logins; forcing expiry on the
#     sops-managed recovery account risks locking out console recovery.
{ lib, ... }:
let
  banner = ''
    Authorized access only. Activity on this system is monitored and logged.
    Disconnect now if you are not an authorized user.
  '';
in
{
  # ── Extra kernel/network sysctls beyond the shared security profile ──────
  boot.kernel.sysctl = {
    "dev.tty.ldisc_autoload" = 0;
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;
    "fs.suid_dumpable" = 0;
    "kernel.core_uses_pid" = 1;
    "kernel.sysrq" = 0;
    "kernel.perf_event_paranoid" = 2;
    "net.ipv4.conf.all.log_martians" = 1;
    "net.ipv4.conf.default.log_martians" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.default.accept_source_route" = 0;
  };

  # ── Blacklist unused/exotic modules (NETW-3200, USB-1000) ────────────────
  # None of these are used on a GCE VM (virtio disks, tailnet-only networking).
  boot.blacklistedKernelModules = [
    "dccp"
    "sctp"
    "rds"
    "tipc"
    "usb-storage"
    "uas"
  ];

  # ── SSH hardening (SSH-7408) ─────────────────────────────────────────────
  services.openssh.settings = {
    MaxAuthTries = 3;
    ClientAliveCountMax = 2;
    AllowAgentForwarding = "no";
    AllowTcpForwarding = "local";
    TCPKeepAlive = "no";
  };

  # ── Stronger password hashing rounds (AUTH-9230). Only affects newly
  #    hashed passwords; existing sops-managed hashes are untouched. ─────────
  security.loginDefs.settings = {
    SHA_CRYPT_MIN_ROUNDS = 10000;
    SHA_CRYPT_MAX_ROUNDS = 65536;
  };

  # ── Legal banners (BANN-7126) ────────────────────────────────────────────
  environment.etc = {
    "issue".text = lib.mkForce banner;
    "issue.net".text = lib.mkForce banner;
  };

  # ── System activity accounting (ACCT-9626) ───────────────────────────────
  services.sysstat.enable = true;
}
