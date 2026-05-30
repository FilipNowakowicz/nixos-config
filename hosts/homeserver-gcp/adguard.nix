_: {
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

      # Web UI credentials. Password is a bcrypt hash (cost 12); plaintext never
      # stored here. Change via sops-backed secret + activation script if needed.
      users = [
        {
          name = "admin";
          password = "$2y$12$zECsUKzXoQAf4JfIhAg8Kez/x9T9KmYnyJovEaEQaeQDJ4FHtrj9q";
        }
      ];
    };
  };

  # DNS (TCP+UDP) and web UI — tailscale0 only; GCP external firewall blocks 53 on public interface.
  networking.firewall.interfaces.tailscale0 = {
    allowedTCPPorts = [
      53
      3001
    ];
    allowedUDPPorts = [ 53 ];
  };
}
