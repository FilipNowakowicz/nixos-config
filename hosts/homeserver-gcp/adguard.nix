{
  config,
  lib,
  pkgs,
  ...
}:
{
  sops.secrets.adguard_admin_password = { };

  services.adguardhome = {
    enable = true;
    mutableSettings = false;
    # Bind to localhost only; nginx proxies HTTPS on port 3001 → here.
    # Direct HTTP access on this port is intentionally unreachable externally.
    host = "127.0.0.1";
    port = 13001;
    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        upstream_dns = [
          "https://1.1.1.1/dns-query"
          "https://8.8.8.8/dns-query"
        ];
        bootstrap_dns = [
          "9.9.9.9"
          "8.8.8.8"
        ];
        upstream_mode = "load_balance";
        cache_enabled = true;
        cache_size = 4194304;
      };
      filters = [
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
          name = "AdGuard DNS filter";
          id = 1;
        }
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt";
          name = "AdAway Default Blocklist";
          id = 2;
        }
      ];
      # Sites that must not be blocked regardless of filter list matches.
      user_rules = [
        "@@||stats.grafana.org^$important"
        "@@||fc.yahoo.com^$important"
      ];

      clients = {
        persistent = [
          {
            name = "main";
            ids = [ "100.111.88.61" ];
            use_global_settings = true;
          }
          {
            name = "mac";
            ids = [ "100.73.117.103" ];
            use_global_settings = true;
          }
          {
            name = "homeserver-gcp";
            ids = [ "100.103.234.89" ];
            use_global_settings = true;
          }
          {
            name = "filips-s24";
            ids = [ "100.87.223.42" ];
            use_global_settings = true;
          }
          {
            name = "filips-tab-s8";
            ids = [ "100.95.25.123" ];
            use_global_settings = true;
          }
        ];
      };
    };
  };

  systemd.services.adguardhome.preStart = lib.mkAfter ''
    user_hash="$(${pkgs.apacheHttpd}/bin/htpasswd -niB admin < "${config.sops.secrets.adguard_admin_password.path}")"
    user_hash="''${user_hash#admin:}"
    umask 077
    {
      printf 'users:\n'
      printf '  - name: admin\n'
      printf '    password: "%s"\n' "$user_hash"
    } > "$RUNTIME_DIRECTORY/adguardhome-users.yaml"
    ${pkgs.yaml-merge}/bin/yaml-merge \
      "$STATE_DIRECTORY/AdGuardHome.yaml" \
      "$RUNTIME_DIRECTORY/adguardhome-users.yaml" \
      > "$STATE_DIRECTORY/AdGuardHome.yaml.tmp"
    mv "$STATE_DIRECTORY/AdGuardHome.yaml.tmp" "$STATE_DIRECTORY/AdGuardHome.yaml"
    chmod 600 "$STATE_DIRECTORY/AdGuardHome.yaml"
    ${lib.getExe config.services.adguardhome.package} \
      -c "$STATE_DIRECTORY/AdGuardHome.yaml" \
      --check-config
  '';

  # DNS (TCP+UDP) and web UI — tailscale0 only; GCP external firewall blocks 53 on public interface.
  networking.firewall.interfaces.tailscale0 = {
    allowedTCPPorts = [
      53
      3001
    ];
    allowedUDPPorts = [ 53 ];
  };
}
