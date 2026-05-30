{ lib, pkgs, ... }:
let
  tailscaleBypassRules = pkgs.writeShellScript "tailscale-bypass-rules" ''
    set -euo pipefail

    ip_bin=${pkgs.iproute2}/bin/ip
    sleep_bin=${pkgs.coreutils}/bin/sleep

    # Wait for tailscale0 to appear (up to 5 s after tailscaled starts).
    for _attempt in 1 2 3 4 5; do
      "$ip_bin" link show tailscale0 >/dev/null 2>&1 && break
      "$sleep_bin" 1
    done

    if ! "$ip_bin" link show tailscale0 >/dev/null 2>&1; then
      # Fail loudly: returning success here meant tailnet traffic could silently
      # fall onto the Mullvad tunnel while the unit reported OK and
      # systemd-failure-notify never fired. A non-zero exit surfaces the
      # condition in `systemctl status` and the failure handler.
      echo "tailscale-bypass-routing: tailscale0 interface not present" >&2
      exit 1
    fi

    # Mullvad installs two policy routing rules: a "lookup main suppress_prefixlength 0"
    # rule and a catch-all that routes all unmarked traffic into Mullvad's VPN table.
    # Mullvad's chosen pref numbers vary between versions and reconnects (observed
    # across three restarts: 112/113 → 109/110 → 48/49), so a fixed pref for our
    # destination-based bypass rule can never reliably beat Mullvad's catch-all.
    #
    # Instead, we place Tailscale's CGNAT ranges in the main routing table.
    # Mullvad's own "lookup main suppress_prefixlength 0" rule then finds the
    # tailscale0 route before its own catch-all fires — the bypass is anchored to
    # Mullvad's fixed lookup-main rule, not to beating its catch-all by pref number.
    # The route is tied to the tailscale0 interface: when tailscaled restarts and
    # recreates the TUN, the kernel auto-removes it and this script re-adds it.
    #
    # Clean up any leftover destination-based policy rules from prior approaches.
    for _pref in 120 117 114 111 50; do
      while "$ip_bin" rule del pref "$_pref" to 100.64.0.0/10 2>/dev/null; do :; done
      while "$ip_bin" -6 rule del pref "$_pref" to fd7a:115c:a1e0::/48 2>/dev/null; do :; done
    done

    # Add the tailnet ranges to the main table. `replace` is idempotent so
    # re-running on reconnect doesn't fail with EEXIST.
    "$ip_bin" route replace 100.64.0.0/10 dev tailscale0 table main
    "$ip_bin" -6 route replace fd7a:115c:a1e0::/48 dev tailscale0 table main

    "$ip_bin" route flush cache 2>/dev/null || true
    "$ip_bin" -6 route flush cache 2>/dev/null || true
  '';
in
{
  networking = {
    networkmanager.enable = true;
    # Required because Mullvad + Tailscale create asymmetric VPN routing on this host.
    # Strict reverse-path filtering drops legitimate tunneled packets in that setup.
    # "loose" keeps a weaker source-reachability check, but relaxes anti-spoofing
    # protection compared with strict mode.
    firewall.checkReversePath = "loose";
    firewall.interfaces.tailscale0 = {
      allowedTCPPorts = [
        22
        24800
        47984
        47989
        48010
      ];
      allowedUDPPorts = [
        47998
        47999
        48000
        48002
        48010
      ];
    };
    # Point to systemd-resolved stub for split DNS (Tailscale tailnet hostnames)
    nameservers = [ "127.0.0.53" ];

    # Mullvad's killswitch (both the connected-state firewall and lockdown mode)
    # lives in its own nftables table. Its output chain runs at priority filter (0)
    # with policy drop and accepts traffic via two mechanisms: ct mark 0x00000f41
    # (Mullvad's split-tunnel conntrack mark) or oif "wg0-mullvad" (traffic already
    # going through the Mullvad tunnel). Neither applies to packets going to tailscale0,
    # so we run our own chain at priority filter-1 (before Mullvad) to set both the
    # conntrack mark (0x00000f41, accepted by Mullvad's ct-mark rule) and the packet
    # mark (0x6d6f6c65, accepted by Mullvad's policy routing bypass at rule 113).
    # Setting the conntrack mark also propagates to return traffic via Mullvad's
    # prerouting chain, so inbound tailscale0 packets are accepted by Mullvad's input
    # chain under the same ct mark 0x00000f41 rule.
    nftables.tables."tailscale-mullvad-compat" = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter - 1;
          oifname "tailscale0" ct mark set 0x00000f41 meta mark set 0x6d6f6c65
        }
      '';
    };
  };

  services = {
    resolved = {
      enable = true;
      settings.Resolve = {
        DNSSEC = "false"; # Tailscale manages its own trust chain
        # Do not publish main.local on hostile/shared LANs. Tailscale MagicDNS
        # remains the durable host-discovery path and avoids resolved's
        # conflict-renaming loop when another peer already owns main.local.
        LLMNR = "false";
        MulticastDNS = "false";
      };
    };

    tailscale = {
      enable = true;
      openFirewall = true;
    };

    mullvad-vpn.enable = true;
  };

  # NetworkManager manages networking; avoid boot blocking on online targets.
  systemd.services = {
    "systemd-networkd-wait-online".enable = lib.mkForce false;
    "NetworkManager-wait-online".enable = lib.mkForce false;

    tailscale-bypass-routing = {
      description = "Keep tailnet traffic off the Mullvad tunnel";
      after = [
        "tailscaled.service"
        "mullvad-daemon.service"
      ];
      wants = [
        "tailscaled.service"
        "mullvad-daemon.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = tailscaleBypassRules;
      };
    };

    # Best-effort re-assertion when either daemon (re)starts. Trailing `|| true`
    # keeps a discovery failure here from marking tailscaled/mullvad-daemon
    # itself failed (postStart -> ExecStartPost, whose non-zero exit fails the
    # parent unit) — common on a cold-boot race before tailnet is up. The
    # dedicated tailscale-bypass-routing.service is the surface that fails
    # loudly on discovery failure.
    tailscaled.postStart = lib.mkAfter "${tailscaleBypassRules} || true";
    mullvad-daemon.postStart = lib.mkAfter "${tailscaleBypassRules} || true";

    # Tailscale coexistence is handled at the nftables layer: outgoing
    # tailscale0 packets are marked with Mullvad's split-tunnel exclusion
    # mark (0x6d6f6c65) so Mullvad's chain accepts them regardless of
    # connection or lockdown state. Lockdown can therefore be left on as
    # a kill switch for all non-Tailscale traffic.
    mullvad-lockdown = {
      description = "Enable Mullvad lockdown mode (kill switch)";
      after = [ "mullvad-daemon.service" ];
      bindsTo = [ "mullvad-daemon.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
          ${pkgs.mullvad-vpn}/bin/mullvad status >/dev/null 2>&1 && break
          ${pkgs.coreutils}/bin/sleep 1
        done
        ${pkgs.mullvad-vpn}/bin/mullvad lockdown-mode set on
      '';
    };
  };
}
