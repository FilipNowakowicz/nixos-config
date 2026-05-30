_: {
  services.adguardhome = {
    enable = true;
    mutableSettings = false;
    host = "0.0.0.0";
    port = 3001;
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
