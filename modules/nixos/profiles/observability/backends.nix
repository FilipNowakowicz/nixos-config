{
  config,
  lib,
  ...
}:
let
  cfg = config.profiles.observability;
in
{
  options.profiles.observability = {
    loki.enable = lib.mkEnableOption "Loki log aggregation backend (stores logs shipped by Alloy)";
  };

  config = lib.mkIf cfg.enable {
    services = {
      loki = lib.mkIf cfg.loki.enable {
        enable = true;
        configuration = {
          analytics.reporting_enabled = false;
          auth_enabled = false;
          server = {
            http_listen_address = "127.0.0.1";
            http_listen_port = 3100;
            grpc_listen_address = "127.0.0.1";
            grpc_listen_port = 9096;
          };
          common = {
            path_prefix = "/var/lib/loki";
            replication_factor = 1;
            # gRPC listens on loopback only, so the ring must advertise loopback
            # too. Otherwise Loki registers the first interface's address and
            # every push and query between its own components is refused.
            instance_addr = "127.0.0.1";
            ring.kvstore.store = "inmemory";
          };
          schema_config.configs = [
            {
              from = "2024-01-01";
              index = {
                prefix = "index_";
                period = "24h";
              };
              object_store = "filesystem";
              schema = "v13";
              store = "tsdb";
            }
          ];
          storage_config.filesystem.directory = "/var/lib/loki/chunks";
          # 30-day retention to keep the local disk bounded on small VMs.
          limits_config.retention_period = "720h";
          compactor = {
            working_directory = "/var/lib/loki/compactor";
            retention_enabled = true;
            delete_request_store = "filesystem";
          };
        };
      };

    };

    systemd.tmpfiles.rules = lib.mkIf cfg.loki.enable [
      "d /var/lib/loki 0750 loki loki -"
      "d /var/lib/loki/chunks 0750 loki loki -"
    ];
  };
}
