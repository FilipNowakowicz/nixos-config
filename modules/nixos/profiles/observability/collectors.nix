{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.observability;
  gen = import ../../../../lib/generators.nix { inherit lib; };
  mkYaml = name: data: (pkgs.formats.yaml { }).generate name data;

  shouldUseIngestAuth = cfg.ingestAuth.username != null && cfg.ingestAuth.passwordFile != null;
  shouldUseRemoteTraceAuth = shouldUseIngestAuth && cfg.collectors.traces.exportURL != null;

  nodeExporterTextfileDir = "/var/lib/node-exporter-textfiles";
  prometheusPort = 9090;
  nodeExporterPort = 9100;
  mkPromScript =
    {
      name,
      lines,
    }:
    let
      filename = if lib.hasSuffix ".prom" name then name else "${name}.prom";
      scriptName = "write-${lib.removeSuffix ".prom" filename}";
      content = lib.concatStringsSep "\n" lines;
    in
    pkgs.writeShellScript scriptName ''
      set -eu

      ${pkgs.coreutils}/bin/install -d -m 0755 ${nodeExporterTextfileDir}
      tmp="$(${pkgs.coreutils}/bin/mktemp "${nodeExporterTextfileDir}/${filename}.tmp.XXXXXX")"
      cleanup() {
        ${pkgs.coreutils}/bin/rm -f "$tmp"
      }
      trap cleanup EXIT

      cat >"$tmp" <<EOF
      ${content}
      EOF
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "${nodeExporterTextfileDir}/${filename}"
      trap - EXIT
    '';
  ingestAuthGroups = lib.optionals (shouldUseIngestAuth && cfg.ingestAuth.group != null) [
    cfg.ingestAuth.group
  ];
  metricsRemoteWriteAuth = lib.optionalAttrs shouldUseIngestAuth {
    basic_auth = {
      inherit (cfg.ingestAuth) username;
      password_file = toString cfg.ingestAuth.passwordFile;
    };
  };

  auditSources = cfg.collectors.audit.sources // cfg.collectors.audit.extraSources;

  mkRelabelRule =
    {
      sourceLabels,
      targetLabel,
      action ? null,
      regex ? null,
      replacement ? null,
    }:
    gen.nestedBlock (
      {
        source_labels = sourceLabels;
        target_label = targetLabel;
      }
      // lib.optionalAttrs (action != null) {
        inherit action;
      }
      // lib.optionalAttrs (regex != null) {
        inherit regex;
      }
      // lib.optionalAttrs (replacement != null) {
        inherit replacement;
      }
    );

  journalRelabelComponent = {
    type = "loki.relabel";
    label = "journal_labels";
    body = {
      forward_to = [ (gen.ref "loki.write.target.receiver") ];
      rule = [
        (mkRelabelRule {
          sourceLabels = [ "__journal__systemd_unit" ];
          targetLabel = "unit";
        })
        (mkRelabelRule {
          sourceLabels = [ "__journal_syslog_identifier" ];
          targetLabel = "syslog_identifier";
        })
        (mkRelabelRule {
          sourceLabels = [ "__journal_priority_keyword" ];
          targetLabel = "priority";
        })
        (mkRelabelRule {
          sourceLabels = [ "__journal__comm" ];
          targetLabel = "comm";
        })
      ];
    };
  };

  defaultJournalSource = {
    type = "loki.source.journal";
    label = "systemd";
    body = {
      forward_to = [ (gen.ref "loki.write.target.receiver") ];
      labels = {
        host = config.networking.hostName;
        job = "systemd-journal";
      };
      relabel_rules = gen.ref "loki.relabel.journal_labels.rules";
      max_age = "12h";
    };
  };

  auditJournalSources = lib.mapAttrsToList (name: source: {
    type = "loki.source.journal";
    label = "audit_${lib.replaceStrings [ "-" ] [ "_" ] name}";
    body = {
      forward_to = [ (gen.ref "loki.write.target.receiver") ];
      inherit (source) matches;
      labels = {
        host = config.networking.hostName;
        job = "audit-journal";
        audit_event_type = source.eventType;
        audit_scope = source.scope;
        audit_source = name;
      }
      // source.labels;
      relabel_rules = gen.ref "loki.relabel.journal_labels.rules";
      format_as_json = source.formatAsJson;
      max_age = "12h";
    };
  }) (lib.filterAttrs (_: source: source.enable) auditSources);

  alloyConfig = gen.toAlloyHCL (
    [
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
      journalRelabelComponent
      defaultJournalSource
    ]
    ++ lib.optionals cfg.collectors.audit.enable auditJournalSources
  );

  sanitizeProbeName =
    name:
    lib.replaceStrings
      [
        "."
        "/"
        ":"
        " "
      ]
      [
        "_"
        "_"
        "_"
        "_"
      ]
      name;

  blackboxProbes = lib.mapAttrsToList (
    name: probe:
    probe
    // {
      inherit name;
      moduleName = "http_${sanitizeProbeName name}";
    }
  ) cfg.collectors.blackbox.probes;

  blackboxConfig = mkYaml "blackbox-exporter.yaml" {
    modules = lib.listToAttrs (
      map (probe: {
        name = probe.moduleName;
        value = {
          prober = "http";
          inherit (probe) timeout;
          http = {
            method = "GET";
            valid_status_codes = probe.expectedStatusCodes;
          }
          // lib.optionalAttrs (probe.headers != { }) {
            inherit (probe) headers;
          }
          // lib.optionalAttrs probe.skipTLSVerify {
            tls_config.insecure_skip_verify = true;
          };
        };
      }) blackboxProbes
    );
  };

  blackboxScrapeConfigs = map (probe: {
    job_name = "blackbox-${probe.name}";
    metrics_path = "/probe";
    params.module = [ probe.moduleName ];
    static_configs = [
      {
        targets = [ probe.url ];
        labels = {
          probe = probe.name;
          target = probe.url;
        };
      }
    ];
    relabel_configs = [
      {
        source_labels = [ "__address__" ];
        target_label = "__param_target";
      }
      {
        source_labels = [ "__param_target" ];
        target_label = "instance";
      }
      {
        target_label = "__address__";
        replacement = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
      }
    ];
  }) blackboxProbes;
in
{
  options.profiles.observability.collectors = {
    metrics = {
      enable = lib.mkEnableOption "Prometheus metrics collection";
      scrapeInterval = lib.mkOption {
        type = lib.types.str;
        default = "15s";
        description = "Default Prometheus scrape interval for local metric collection.";
      };
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

    blackbox = {
      enable = lib.mkEnableOption "Prometheus blackbox HTTP probes";

      probes = lib.mkOption {
        type =
          with lib.types;
          attrsOf (
            submodule (_: {
              options = {
                url = lib.mkOption {
                  type = str;
                  description = "Absolute URL to probe from this host.";
                  example = "https://homeserver-gcp.example.ts.net/grafana/";
                };

                expectedStatusCodes = lib.mkOption {
                  type = listOf int;
                  default = [ 200 ];
                  description = "HTTP status codes treated as success for this probe.";
                };

                timeout = lib.mkOption {
                  type = str;
                  default = "10s";
                  description = "Probe timeout passed to blackbox exporter.";
                };

                headers = lib.mkOption {
                  type = attrsOf str;
                  default = { };
                  description = "Optional HTTP headers sent with the probe request.";
                };

                skipTLSVerify = lib.mkOption {
                  type = bool;
                  default = false;
                  description = "Whether to skip TLS certificate verification for this probe.";
                };
              };
            })
          );
        default = { };
        description = "Named HTTP probes scraped through the local blackbox exporter.";
      };
    };

    audit = {
      enable = lib.mkEnableOption "narrow audit-focused journald streams for Loki";

      sources = lib.mkOption {
        type =
          with lib.types;
          attrsOf (
            submodule (_: {
              options = {
                enable = lib.mkOption {
                  type = bool;
                  default = true;
                  description = "Whether to emit this audit stream.";
                };

                matches = lib.mkOption {
                  type = str;
                  description = "systemd journal match string used by Alloy for this audit stream.";
                  example = "SYSLOG_IDENTIFIER=sudo";
                };

                eventType = lib.mkOption {
                  type = str;
                  description = "Stable audit event type label for this stream.";
                  example = "sudo";
                };

                scope = lib.mkOption {
                  type = str;
                  description = "Operational scope label attached to this audit stream.";
                  example = "operator-actions";
                };

                labels = lib.mkOption {
                  type = attrsOf str;
                  default = { };
                  description = "Additional static labels attached to this audit stream.";
                };

                formatAsJson = lib.mkOption {
                  type = bool;
                  default = false;
                  description = "Whether to forward full journal entries as JSON for this audit stream.";
                };
              };
            })
          );
        default = {
          sudo = {
            matches = "SYSLOG_IDENTIFIER=sudo";
            eventType = "sudo";
            scope = "operator-actions";
          };
          ssh = {
            matches = "_SYSTEMD_UNIT=sshd.service";
            eventType = "ssh";
            scope = "remote-access";
          };
          service-failures = {
            matches = "SYSLOG_IDENTIFIER=systemd PRIORITY=3";
            eventType = "service_failure";
            scope = "service-health";
          };
        };
        description = ''
          Built-in audit journald streams. These are intentionally narrow and
          focus on events that are likely to matter during incident review.
        '';
      };

      extraSources = lib.mkOption {
        type =
          with lib.types;
          attrsOf (
            submodule (_: {
              options = {
                enable = lib.mkOption {
                  type = bool;
                  default = true;
                  description = "Whether to emit this extra audit stream.";
                };

                matches = lib.mkOption {
                  type = str;
                  description = "systemd journal match string used by Alloy for this audit stream.";
                };

                eventType = lib.mkOption {
                  type = str;
                  description = "Stable audit event type label for this stream.";
                };

                scope = lib.mkOption {
                  type = str;
                  description = "Operational scope label attached to this audit stream.";
                };

                labels = lib.mkOption {
                  type = attrsOf str;
                  default = { };
                  description = "Additional static labels attached to this audit stream.";
                };

                formatAsJson = lib.mkOption {
                  type = bool;
                  default = false;
                  description = "Whether to forward full journal entries as JSON for this audit stream.";
                };
              };
            })
          );
        default = { };
        description = ''
          Host-specific audit journald streams merged on top of the built-in
          sources. Use this for additional narrow selectors such as a stable
          secret materialization unit if a host exposes one.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      lib.profiles.observability = {
        inherit mkPromScript nodeExporterTextfileDir;
      };
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion =
            !(
              cfg.collectors.metrics.enable
              && shouldUseIngestAuth
              && cfg.collectors.metrics.remoteWriteURL == null
              && !cfg.mimir.enable
            );
          message = ''
            profiles.observability.ingestAuth credentials are set but collectors.metrics.remoteWriteURL
            is null and mimir is disabled; the auth will not be applied to any metrics remote-write
            destination. Set remoteWriteURL or enable mimir.
          '';
        }
        {
          assertion = !shouldUseRemoteTraceAuth || cfg.ingestAuth.serviceEnvironmentFile != null;
          message = ''
            profiles.observability.ingestAuth.serviceEnvironmentFile must be set when
            authenticated remote trace export is enabled, because the OpenTelemetry
            collector basicauth extension reads BASICAUTH_PASSWORD from an env file.
          '';
        }
        {
          assertion = !cfg.collectors.blackbox.enable || cfg.collectors.metrics.enable;
          message = "profiles.observability.collectors.blackbox.enable requires profiles.observability.collectors.metrics.enable";
        }
        {
          assertion = !cfg.collectors.blackbox.enable || cfg.collectors.blackbox.probes != { };
          message = "profiles.observability.collectors.blackbox.enable requires at least one probe definition";
        }
      ];

      services = {
        prometheus = lib.mkIf cfg.collectors.metrics.enable {
          enable = true;
          listenAddress = "127.0.0.1";
          port = prometheusPort;
          retentionTime = "24h";
          globalConfig = {
            scrape_interval = cfg.collectors.metrics.scrapeInterval;
            external_labels.host = config.networking.hostName;
          };

          exporters.node = {
            enable = true;
            listenAddress = "127.0.0.1";
            port = nodeExporterPort;
            enabledCollectors = [
              "cpu"
              "filesystem"
              "loadavg"
              "meminfo"
              "netdev"
              "powersupplyclass"
              "systemd"
              "textfile"
              "thermal_zone"
            ];
            extraFlags = [ "--collector.textfile.directory=${nodeExporterTextfileDir}" ];
          };

          scrapeConfigs = [
            {
              job_name = "prometheus";
              static_configs = [ { targets = [ "127.0.0.1:${toString prometheusPort}" ]; } ];
            }
            {
              job_name = "node";
              static_configs = [ { targets = [ "127.0.0.1:${toString nodeExporterPort}" ]; } ];
            }
          ]
          ++ lib.optionals cfg.collectors.blackbox.enable blackboxScrapeConfigs;

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

          exporters.blackbox = lib.mkIf cfg.collectors.blackbox.enable {
            enable = true;
            listenAddress = "127.0.0.1";
            configFile = blackboxConfig;
          };
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

      system.activationScripts.exportSystemMetadata.text = lib.mkIf cfg.collectors.metrics.enable "${
        mkPromScript
        {
          name = "system_metadata.prom";
          lines = [
            "nixos_system_activated_at_seconds $(${pkgs.coreutils}/bin/date +%s)"
          ]
          ++ lib.optionals (config.system.configurationRevision != null) [
            ''nixos_system_revision_info{revision="${config.system.configurationRevision}"} 1''
          ];
        }
      }";

      systemd = {
        tmpfiles.rules = lib.mkIf cfg.collectors.metrics.enable [
          "d /var/lib/prometheus2 0750 prometheus prometheus -"
          "d ${nodeExporterTextfileDir} 0755 root root -"
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
    })
  ];
}
