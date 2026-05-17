{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.observability;
  gen = import ../../../../lib/generators.nix { inherit lib; };

  shouldUseIngestAuth = cfg.ingestAuth.username != null && cfg.ingestAuth.passwordFile != null;
  shouldUseRemoteTraceAuth = shouldUseIngestAuth && cfg.collectors.traces.exportURL != null;
  ingestAuthGroups = lib.optionals (shouldUseIngestAuth && cfg.ingestAuth.group != null) [
    cfg.ingestAuth.group
  ];
  metricsRemoteWriteAuth = lib.optionalAttrs shouldUseIngestAuth {
    basic_auth = {
      inherit (cfg.ingestAuth) username;
      password_file = toString cfg.ingestAuth.passwordFile;
    };
  };

  alloyConfig = gen.toAlloyHCL [
    {
      type = "loki.write";
      label = "target";
      body = {
        endpoint = gen.nestedBlock (
          {
            url = cfg.collectors.logs.pushURL;
          }
          // lib.optionalAttrs shouldUseIngestAuth {
            basic_auth = gen.nestedBlock {
              password_file = toString cfg.ingestAuth.passwordFile;
              inherit (cfg.ingestAuth) username;
            };
          }
        );
      };
    }
    {
      type = "loki.source.journal";
      label = "systemd";
      body = {
        forward_to = [ (gen.ref "loki.write.target.receiver") ];
        labels = {
          host = config.networking.hostName;
          job = "systemd-journal";
        };
        max_age = "12h";
      };
    }
  ];
in
{
  options.profiles.observability.collectors = {
    metrics = {
      enable = lib.mkEnableOption "Prometheus metrics collection";
      remoteWriteURL = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Prometheus remote write endpoint. When null and mimir.enable is true, writes to the local Mimir instance instead.";
        example = "https://homeserver-gcp.example.ts.net/obs/mimir/api/v1/push";
      };
    };

    logs = {
      enable = lib.mkEnableOption "Loki log shipping";
      pushURL = lib.mkOption {
        type = lib.types.str;
        default = "http://127.0.0.1:3100/loki/api/v1/push";
        description = "Loki push URL used by Alloy";
      };
    };

    traces = {
      enable = lib.mkEnableOption "OpenTelemetry trace pipeline";
      receiverGRPCEndpoint = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:14317";
        description = "OpenTelemetry Collector OTLP gRPC receiver endpoint";
      };
      receiverHTTPEndpoint = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:14318";
        description = "OpenTelemetry Collector OTLP HTTP receiver endpoint";
      };
      exportURL = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Remote OTLP/HTTP endpoint for trace export. When null, traces are forwarded to the local Tempo instance instead.";
        example = "https://homeserver-gcp.example.ts.net/obs/otlp/v1/traces";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !shouldUseRemoteTraceAuth || cfg.ingestAuth.serviceEnvironmentFile != null;
        message = ''
          profiles.observability.ingestAuth.serviceEnvironmentFile must be set when
          authenticated remote trace export is enabled, because the OpenTelemetry
          collector basicauth extension reads BASICAUTH_PASSWORD from an env file.
        '';
      }
    ];

    services = {
      prometheus = lib.mkIf cfg.collectors.metrics.enable {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9090;
        retentionTime = "24h";
        globalConfig = {
          scrape_interval = "15s";
          external_labels.host = config.networking.hostName;
        };

        exporters.node = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = 9100;
          enabledCollectors = [
            "cpu"
            "filesystem"
            "loadavg"
            "meminfo"
            "netdev"
            "systemd"
            "textfile"
            "thermal_zone"
          ];
          extraFlags = [ "--collector.textfile.directory=/var/lib/node-exporter-textfiles" ];
        };

        scrapeConfigs = [
          {
            job_name = "prometheus";
            static_configs = [ { targets = [ "127.0.0.1:9090" ]; } ];
          }
          {
            job_name = "node";
            static_configs = [ { targets = [ "127.0.0.1:9100" ]; } ];
          }
        ];

        remoteWrite =
          if cfg.collectors.metrics.remoteWriteURL != null then
            [
              (
                {
                  url = cfg.collectors.metrics.remoteWriteURL;
                }
                // metricsRemoteWriteAuth
              )
            ]
          else
            lib.optionals cfg.mimir.enable [
              {
                url = "http://127.0.0.1:9009/api/v1/push";
              }
            ];
      };

      alloy = lib.mkIf cfg.collectors.logs.enable {
        enable = true;
        configPath = "/etc/alloy/config.alloy";
      };

      "opentelemetry-collector" = lib.mkIf cfg.collectors.traces.enable {
        enable = true;
        # contrib distribution required for the basicauth extension used for authenticated remote export
        package = pkgs.opentelemetry-collector-contrib;
        settings = {
          receivers.otlp.protocols = {
            grpc.endpoint = cfg.collectors.traces.receiverGRPCEndpoint;
            http.endpoint = cfg.collectors.traces.receiverHTTPEndpoint;
          };
          processors.batch = { };
          extensions = lib.optionalAttrs shouldUseIngestAuth {
            "basicauth/client" = {
              client_auth = {
                inherit (cfg.ingestAuth) username;
                password = "\${env:BASICAUTH_PASSWORD}";
              };
            };
          };
          exporters =
            if cfg.collectors.traces.exportURL != null then
              {
                otlphttp = {
                  endpoint = cfg.collectors.traces.exportURL;
                }
                // lib.optionalAttrs shouldUseIngestAuth {
                  auth.authenticator = "basicauth/client";
                };
              }
            else
              {
                otlp = {
                  endpoint = "127.0.0.1:4317";
                  tls.insecure = true;
                };
              };
          service.pipelines.traces = {
            receivers = [ "otlp" ];
            processors = [ "batch" ];
            exporters = if cfg.collectors.traces.exportURL != null then [ "otlphttp" ] else [ "otlp" ];
          };
          service.extensions = lib.optionals shouldUseIngestAuth [ "basicauth/client" ];
        };
      };
    };

    environment.etc = lib.mkIf cfg.collectors.logs.enable {
      "alloy/config.alloy".text = alloyConfig;
    };

    systemd = {
      tmpfiles.rules = lib.mkIf cfg.collectors.metrics.enable [
        "d /var/lib/prometheus2 0750 prometheus prometheus -"
        "d /var/lib/node-exporter-textfiles 0755 root root -"
      ];

      services = {
        prometheus = lib.mkIf cfg.collectors.metrics.enable {
          serviceConfig.SupplementaryGroups = ingestAuthGroups;
        };

        prometheus-node-exporter = lib.mkIf cfg.collectors.metrics.enable {
          after = [ "systemd-tmpfiles-setup.service" ];
          wants = [ "systemd-tmpfiles-setup.service" ];
        };

        alloy = lib.mkIf cfg.collectors.logs.enable {
          after = lib.optionals cfg.loki.enable [ "loki.service" ];
          requires = lib.optionals cfg.loki.enable [ "loki.service" ];
          serviceConfig.SupplementaryGroups = [ "systemd-journal" ] ++ ingestAuthGroups;
        };

        "opentelemetry-collector" =
          lib.mkIf (cfg.collectors.traces.enable && cfg.ingestAuth.serviceEnvironmentFile != null)
            {
              serviceConfig = {
                EnvironmentFile = cfg.ingestAuth.serviceEnvironmentFile;
                SupplementaryGroups = ingestAuthGroups;
              };
            };
      };
    };
  };
}
