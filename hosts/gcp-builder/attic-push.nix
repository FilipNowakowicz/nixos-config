# Push every path this builder adds to its store into the fleet attic cache on
# homeserver-gcp (#631). `attic watch-store` runs beside the builds rather
# than as a post-build-hook, so a slow or unreachable cache never holds up or
# fails a build: the watcher just restarts until the homeserver answers.
# Paths signed by cache.nixos.org are skipped (the cache lists it upstream).
#
# The builder has no sops, so the push token is seeded by hand like the
# prebuild notification URL (./CLAUDE.md, "Binary cache push"). Without the
# file the watcher does not start; the path unit starts it once it appears.
{ hostRegistry, pkgs, ... }:
let
  inherit ((import ../../lib/binary-cache.nix)) fleetCache;
  tokenFile = "/var/lib/attic-push/token";
  endpoint = "https://${hostRegistry.homeserver-gcp.tailnetFQDN}:${toString fleetCache.port}/";

  # A static client config whose token is read from the unit's credential,
  # so the token is never in argv, the store or a writable config file.
  clientConfig = pkgs.writeTextDir "attic/config.toml" ''
    default-server = "${fleetCache.name}"

    [servers.${fleetCache.name}]
    endpoint = "${endpoint}"
    token-file = "/run/credentials/attic-watch-store.service/token"
  '';
in
{
  systemd = {
    tmpfiles.rules = [ "d /var/lib/attic-push 0700 root root -" ];

    services.attic-watch-store = {
      description = "Push new store paths to the ${fleetCache.name} attic cache";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "nix-daemon.service"
        "tailscaled.service"
      ];
      unitConfig = {
        ConditionPathExists = tokenFile;
        # Keep retrying however long the homeserver is away.
        StartLimitIntervalSec = 0;
      };
      environment.XDG_CONFIG_HOME = "${clientConfig}";
      serviceConfig = {
        DynamicUser = true;
        LoadCredential = [ "token:${tokenFile}" ];
        # Two uploads at a time: the homeserver compresses every chunk on 2 vCPUs.
        ExecStart = "${pkgs.attic-client}/bin/attic watch-store --jobs 2 ${fleetCache.name}:${fleetCache.name}";
        Restart = "always";
        RestartSec = 60;
        # Builds come first on this box.
        CPUWeight = 10;
        IOWeight = 10;
        Nice = 15;
        MemoryMax = "1G";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    # Starts the watcher as soon as the token is seeded, without a reboot.
    paths.attic-watch-store = {
      wantedBy = [ "paths.target" ];
      pathConfig.PathExists = tokenFile;
    };
  };
}
