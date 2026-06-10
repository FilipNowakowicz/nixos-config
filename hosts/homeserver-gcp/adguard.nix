{
  config,
  lib,
  pkgs,
  hostRegistry,
  ...
}:
let
  # AdGuard per-client policy keyed by Tailscale IP. NixOS hosts derive their
  # IP from the host registry (lib/hosts.nix) so a re-key only needs updating
  # in one place; non-NixOS personal devices (phones/tablets) can't live in
  # the registry (no `system`, no nixosConfiguration) and are listed
  # separately below.
  registryClients =
    map
      (name: {
        inherit name;
        ids = [ hostRegistry.${name}.tailscale.ip4 ];
        use_global_settings = true;
      })
      [
        "main"
        "mac"
        "homeserver-gcp"
      ];

  # Personal phones/tablets: not NixOS hosts, so not in lib/hosts.nix. Tailscale
  # IPs are stable per node-key but must be updated here manually if the device
  # is re-keyed (e.g. re-installed or re-added to the tailnet).
  nonRegistryClients = [
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
in
{
  # adguardhome runs as a systemd DynamicUser, so the "adguardhome" user/group
  # only exist while the unit is running and cannot be resolved during
  # activation, when setupSecrets runs with adguardhome stopped. Own the
  # secret by root and grant read access through a static supplementary
  # group the adguardhome unit joins (same pattern as mimir-webhook in
  # hosts/homeserver-gcp/default.nix).
  sops.secrets.adguard_admin_password = {
    mode = "0440";
    group = "adguardhome-secrets";
    restartUnits = [ "adguardhome.service" ];
  };

  users.groups.adguardhome-secrets = { };
  systemd.services.adguardhome.serviceConfig.SupplementaryGroups = [ "adguardhome-secrets" ];

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
        persistent = registryClients ++ nonRegistryClients;
      };
    };
  };

  systemd.services.adguardhome.preStart = lib.mkAfter ''
    user_hash="$(${pkgs.apacheHttpd}/bin/htpasswd -niBC 12 admin < "${config.sops.secrets.adguard_admin_password.path}")"
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
