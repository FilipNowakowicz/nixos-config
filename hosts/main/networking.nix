{ lib, pkgs, ... }:
let
  tailscaleBypassRules = pkgs.writeShellScript "tailscale-bypass-rules" ''
    set -euo pipefail

    ip_bin=${pkgs.iproute2}/bin/ip
    awk_bin=${pkgs.gawk}/bin/awk
    sleep_bin=${pkgs.coreutils}/bin/sleep

    tailscale_table=""
    for _attempt in 1 2 3 4 5; do
      tailscale_table=$(
        {
          "$ip_bin" rule show
          "$ip_bin" -6 rule show
          "$ip_bin" -o route show table all
          "$ip_bin" -o -6 route show table all
        } | "$awk_bin" '
          $0 ~ /^52[0-9][0-9]: from all lookup [0-9]+$/ { print $NF; exit }
          $1 ~ /^100\./ && $0 ~ /dev tailscale0/ && $0 ~ / table [0-9]+/ {
            for (i = 1; i <= NF; i++) if ($i == "table" && $(i + 1) ~ /^[0-9]+$/) { print $(i + 1); exit }
          }
          $1 ~ /^fd7a:115c:a1e0::/ && $0 ~ /dev tailscale0/ && $0 ~ / table [0-9]+/ {
            for (i = 1; i <= NF; i++) if ($i == "table" && $(i + 1) ~ /^[0-9]+$/) { print $(i + 1); exit }
          }
        '
      )

      if [ -n "$tailscale_table" ]; then
        break
      fi

      "$sleep_bin" 1
    done

    if [ -z "''${tailscale_table:-}" ]; then
      # Fail loudly: returning success here meant tailnet traffic could silently
      # fall onto the Mullvad tunnel while the unit reported OK and
      # systemd-failure-notify never fired. A non-zero exit surfaces the
      # condition in `systemctl status` and the failure handler.
      echo "tailscale-bypass-routing: could not discover tailscale routing table" >&2
      exit 1
    fi

    # Mullvad installs broad policy routing rules that can capture tailnet
    # traffic on this workstation. Reassert destination-specific rules with a
    # higher priority than Mullvad's catch-all policy rule so 100.x/ts.net
    # traffic always uses Tailscale's table. With `set -e` each `rule add`
    # below aborts the script (and fails the unit) if the kernel rejects it,
    # so a half-applied bypass is reported rather than swallowed.
    while "$ip_bin" rule del pref 120 to 100.64.0.0/10 2>/dev/null; do :; done
    while "$ip_bin" rule del pref 117 to 100.64.0.0/10 2>/dev/null; do :; done
    while "$ip_bin" rule del pref 114 to 100.64.0.0/10 2>/dev/null; do :; done
    "$ip_bin" rule add pref 114 to 100.64.0.0/10 lookup "$tailscale_table"

    while "$ip_bin" -6 rule del pref 120 to fd7a:115c:a1e0::/48 2>/dev/null; do :; done
    while "$ip_bin" -6 rule del pref 117 to fd7a:115c:a1e0::/48 2>/dev/null; do :; done
    while "$ip_bin" -6 rule del pref 114 to fd7a:115c:a1e0::/48 2>/dev/null; do :; done
    "$ip_bin" -6 rule add pref 114 to fd7a:115c:a1e0::/48 lookup "$tailscale_table"

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
    # lives in its own nftables table and uses a per-packet mark (0x6d6f6c65) as
    # the escape hatch for split-tunnel exclusions. Marking outgoing tailscale0
    # packets with that value before Mullvad's chain runs (priority -1 vs 0)
    # makes Mullvad accept them regardless of connection or lockdown state, so
    # both VPNs can run concurrently without disabling the kill switch.
    nftables.tables."tailscale-mullvad-compat" = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority -1;
          oifname "tailscale0" meta mark set 0x6d6f6c65
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

    tailscaled.postStart = lib.mkAfter "${tailscaleBypassRules}";
    mullvad-daemon.postStart = lib.mkAfter "${tailscaleBypassRules}";

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
