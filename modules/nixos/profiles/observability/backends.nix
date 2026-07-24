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
    tempo.enable = lib.mkEnableOption "Tempo distributed tracing backend (receives OTLP traces from collectors)";
    mimir.enable = lib.mkEnableOption "Mimir long-term metrics storage backend (Prometheus remote write target)";
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

      tempo = lib.mkIf cfg.tempo.enable {
        enable = true;
        settings = {
          usage_report.reporting_enabled = false;
          server = {
            http_listen_address = "127.0.0.1";
            http_listen_port = 3200;
            grpc_listen_address = "127.0.0.1";
            grpc_listen_port = 3201;
          };
          distributor.receivers.otlp.protocols = {
            grpc.endpoint = "127.0.0.1:4317";
            http.endpoint = "127.0.0.1:4318";
          };
          storage = {
            trace = {
              backend = "local";
              local.path = "/var/lib/tempo/blocks";
              wal.path = "/var/lib/tempo/wal";
            };
          };
          # Tempo 3.x runs the monolithic `target: all` through a new
          # live-store / block-builder / backend-scheduler pipeline (the old
          # top-level `compactor` block is gone). It does NOT require Kafka in
          # monolithic mode — the distributor pushes spans in-process to the
          # live-store, which serves recent queries and flushes blocks to the
          # `storage.trace` backend above. These components default their WAL
          # and marker dirs under a hardcoded `/var/tempo`, which the `tempo`
          # service user (StateDirectory=/var/lib/tempo) cannot create, so
          # redirect each onto the state dir.
          live_store = {
            wal.path = "/var/lib/tempo/live-store/traces";
            shutdown_marker_dir = "/var/lib/tempo/live-store/shutdown-marker";
          };
          block_builder.wal.path = "/var/lib/tempo/block-builder/traces";
          backend_scheduler = {
            local_work_path = "/var/lib/tempo/backend-scheduler";
            # 7-day trace retention — traces are short-lived diagnostic data.
            # Replaces the 2.x `compactor.compaction.block_retention`.
            provider.compaction.compaction.block_retention = "168h";
          };
        };
      };

      mimir = lib.mkIf cfg.mimir.enable {
        enable = true;
        configuration = {
          usage_stats.enabled = false;
          multitenancy_enabled = false;
          server = {
            http_listen_address = "127.0.0.1";
            http_listen_port = 9009;
            grpc_listen_address = "127.0.0.1";
          };
          # Mimir 3.1 starts a memberlist gossip listener on *:7946 by
          # default even with inmemory ring kvstores. Bind it to loopback so
          # it doesn't show up as an unexpected listener on the tailnet
          # interface (single-instance setup, no gossip needed).
          memberlist.bind_addr = [ "127.0.0.1" ];
          blocks_storage = {
            backend = "filesystem";
            filesystem.dir = "/var/lib/mimir/blocks";
          };
          # Every ring must declare instance_addr explicitly — Mimir's default
          # interface_names list is [eth0, en0], which doesn't exist on GCE
          # (ens4), so ring lifecyclers fail to start without this. Loopback is
          # correct for our single-instance setup with inmemory kvstores.
          compactor = {
            data_dir = "/var/lib/mimir/compactor";
            sharding_ring = {
              instance_addr = "127.0.0.1";
              kvstore.store = "inmemory";
            };
          };
          distributor.ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "inmemory";
          };
          ingester.ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "inmemory";
            replication_factor = 1;
          };
          ruler.ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "inmemory";
          };
          # The query-frontend advertises its own address to the scheduler
          # (so the scheduler can push finished query results back) via
          # frontend.address, auto-detected from frontend.instance_interface_names
          # (default [ens4, tailscale0] on this host) when unset. That picks
          # ens4's address, but server.grpc_listen_address is 127.0.0.1-only,
          # so the scheduler's callback gets connection-refused and every
          # query times out ("no data" in Grafana) even though ingestion
          # keeps working. Same class of bug as the rings above, just on the
          # frontend rather than a sharding ring.
          frontend.address = "127.0.0.1";
          # Use the read-only `local` backend, not `filesystem`. The filesystem
          # object-store backend expects rule groups written through the ruler
          # API in its own object layout and will not parse human-provisioned
          # rule YAML dropped on disk. The `local` backend reads standard
          # Prometheus `groups:` YAML from <directory>/<tenant>/<namespace>,
          # which is exactly what mimir.service's preStart writes
          # (/var/lib/mimir/rules/anonymous/infrastructure-alerts.yaml).
          ruler_storage = {
            backend = "local";
            local.directory = "/var/lib/mimir/rules";
          };
          store_gateway.sharding_ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "inmemory";
            replication_factor = 1;
          };
          alertmanager.sharding_ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "inmemory";
          };
          alertmanager_storage = {
            backend = "filesystem";
            filesystem.dir = "/var/lib/mimir/alertmanager";
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
