_: {
  services.adguardhome = {
    enable = true;
    mutableSettings = true;
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
      };
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
