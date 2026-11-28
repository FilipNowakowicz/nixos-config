# Fleet binary cache (#631): atticd behind a tailnet-only nginx listener.
#
# - Chunks live in a GCS bucket (infra/cache.tf) through the S3-compatible XML
#   API; the only local state is attic's sqlite database under
#   /var/lib/private/atticd, a few MB per thousand paths.
# - gcp-builder pushes every build (hosts/gcp-builder/attic-push.nix);
#   main, this host and the builder substitute from it
#   (modules/nixos/profiles/fleet-cache.nix).
# - Retention: objects untouched for `retentionPeriod` are dropped by attic's
#   garbage collector, which then deletes their orphaned chunks from GCS.
# - The cache is rebuildable, so nothing here is backed up. The signing key
#   and JWT secret are in sops; atticd-init re-creates the cache with the same
#   key after the database is lost. Empty the bucket in that case (see
#   ./CLAUDE.md), since chunks the new database does not know are never
#   collected.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.homeserverAttic;
  inherit ((import ../../lib/binary-cache.nix)) fleetCache;

  local = "http://127.0.0.1:${toString cfg.listenPort}";

  # atticadm only needs the JWT settings to mint atticd-init's token, but it
  # parses the whole file, so it gets the server's own settings.
  adminConfig = (pkgs.formats.toml { }).generate "atticd-admin.toml" config.services.atticd.settings;

  # Idempotent: creates the cache on first run, then re-asserts its keypair,
  # visibility, priority and retention on every run, and fails if the cache
  # does not sign with the key the fleet trusts.
  initScript = pkgs.writeShellApplication {
    name = "atticd-init";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      config.services.atticd.package
    ];
    text = ''
      api="${local}/_api/v1/cache-config/${cfg.cacheName}"
      headers="$RUNTIME_DIRECTORY/headers"

      for _ in $(seq 60); do
        if curl -sS -o /dev/null -H 'Host: ${cfg.fqdn}' '${local}/'; then
          break
        fi
        sleep 2
      done

      # A ten-minute token for this cache only, passed in a header file so it
      # never appears in argv.
      token=$(atticadm -f ${adminConfig} make-token --sub atticd-init --validity '10 minutes' \
        --pull '${cfg.cacheName}' --create-cache '${cfg.cacheName}' \
        --configure-cache '${cfg.cacheName}' --configure-cache-retention '${cfg.cacheName}')
      printf 'Authorization: Bearer %s\nHost: ${cfg.fqdn}\n' "$token" >"$headers"
      unset token

      keypair=$(tr -d '\n' <"$CREDENTIALS_DIRECTORY/signing-key")
      settings=$(jq -n --arg k "$keypair" '{
        keypair: { Keypair: $k },
        is_public: true,
        store_dir: "/nix/store",
        priority: 41,
        upstream_cache_key_names: [ "cache.nixos.org-1" ]
      }')
      unset keypair

      code=$(curl -sS -o /dev/null -w '%{http_code}' -H @"$headers" "$api")
      case "$code" in
      200) ;;
      404)
        curl -fsS -o /dev/null -X POST -H @"$headers" -H 'Content-Type: application/json' \
          --data-binary @- "$api" <<<"$settings"
        echo "created cache ${cfg.cacheName}"
        ;;
      *)
        echo "unexpected HTTP $code reading cache ${cfg.cacheName}" >&2
        exit 1
        ;;
      esac

      # retention_period "Global" follows garbage-collection.default-retention-period.
      jq '. + { retention_period: "Global" } | del(.store_dir)' <<<"$settings" |
        curl -fsS -o /dev/null -X PATCH -H @"$headers" -H 'Content-Type: application/json' \
          --data-binary @- "$api"
      unset settings

      actual=$(curl -fsS -H @"$headers" "$api" | jq -r .public_key)
      if [[ "$actual" != '${cfg.publicKey}' ]]; then
        echo "cache ${cfg.cacheName} signs with $actual, but the fleet trusts ${cfg.publicKey}" >&2
        exit 1
      fi
      echo "cache ${cfg.cacheName} configured; public key ${cfg.publicKey}"
    '';
  };
in
{
  options.profiles.homeserverAttic = {
    enable = lib.mkEnableOption "the fleet attic binary cache";

    fqdn = lib.mkOption {
      type = lib.types.str;
      description = "Tailnet FQDN the cache is served under (nginx server name and attic allowed host).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = fleetCache.port;
      description = "Tailnet-facing HTTPS port of the nginx listener.";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 18180;
      description = "Loopback port atticd listens on behind nginx.";
    };

    cacheName = lib.mkOption {
      type = lib.types.str;
      default = fleetCache.name;
      description = "The attic cache atticd-init creates and configures.";
    };

    publicKey = lib.mkOption {
      type = lib.types.str;
      default = fleetCache.publicKey;
      description = "Public key the cache must sign with; atticd-init fails on a mismatch.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Environment file with ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64 and, for S3
        storage, AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
      '';
    };

    signingKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Nix secret signing key (`nix key generate-secret`) of the cache.";
    };

    storage = lib.mkOption {
      inherit ((pkgs.formats.toml { })) type;
      description = "attic `[storage]` table.";
    };

    retentionPeriod = lib.mkOption {
      type = lib.types.str;
      default = "30 days";
      description = "Objects neither created nor fetched within this period are garbage-collected.";
    };

    sslCertificate = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nginx-certs/homeserver-gcp.crt";
      description = "TLS certificate for the listener (the tailscale cert nginx.nix uses).";
    };

    sslCertificateKey = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nginx-certs/homeserver-gcp.key";
      description = "TLS key for the listener.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.atticd = {
      enable = true;
      inherit (cfg) environmentFile;
      settings = {
        listen = "127.0.0.1:${toString cfg.listenPort}";
        # nginx forwards $host, which carries no port.
        allowed-hosts = [ cfg.fqdn ];
        api-endpoint = "https://${cfg.fqdn}:${toString cfg.port}/";
        inherit (cfg) storage;
        # Level 3 instead of 8: this 2-vCPU host compresses every pushed
        # chunk, and the storage it saves is cents.
        compression = {
          type = "zstd";
          level = 3;
        };
        garbage-collection = {
          interval = "12 hours";
          default-retention-period = cfg.retentionPeriod;
        };
      };
    };

    # For minting tokens by hand (./CLAUDE.md); holds no secrets, which come
    # from the environment file.
    environment.etc."atticd/admin.toml".source = adminConfig;

    systemd = {
      services.atticd = {
        # GCS accepts the aws-sdk's default checksum headers today; asking for
        # them only where S3 requires them keeps a GCS interop change from
        # breaking uploads.
        environment = {
          AWS_REQUEST_CHECKSUM_CALCULATION = "when_required";
          AWS_RESPONSE_CHECKSUM_VALIDATION = "when_required";
        };
        # A 4 GB host that runs the monitoring stack: a push burst may slow
        # the cache down but must never starve the services next to it
        # (Memory-heavy gotcha in ./CLAUDE.md).
        serviceConfig = {
          MemoryHigh = "384M";
          MemoryMax = "640M";
          MemorySwapMax = "256M";
          OOMScoreAdjust = 500;
          CPUWeight = 20;
          IOWeight = 20;
        };
      };

      # Not wanted by multi-user.target, so a switch never waits on it or
      # fails because of it; the timer runs it shortly after boot or a
      # switch, then twice a day to re-assert the cache settings.
      services.atticd-init = {
        description = "Create and configure the ${cfg.cacheName} attic cache";
        after = [ "atticd.service" ];
        requires = [ "atticd.service" ];
        restartTriggers = [ initScript ];
        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          EnvironmentFile = cfg.environmentFile;
          LoadCredential = [ "signing-key:${cfg.signingKeyFile}" ];
          RuntimeDirectory = "atticd-init";
          UMask = "0077";
          ExecStart = lib.getExe initScript;
          TimeoutStartSec = "5min";
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          NoNewPrivileges = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
      };

      timers.atticd-init = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "30s";
          OnUnitActiveSec = "12h";
        };
      };
    };

    services.nginx.virtualHosts.attic = {
      onlySSL = true;
      serverName = cfg.fqdn;
      listen = [
        {
          addr = "0.0.0.0";
          inherit (cfg) port;
          ssl = true;
        }
      ];
      inherit (cfg) sslCertificate sslCertificateKey;
      extraConfig = ''
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Content-Type-Options "nosniff" always;
      '';
      locations."/" = {
        proxyPass = local;
        # Pushes stream NARs of any size and downloads stream reassembled
        # chunks. Buffering either would spool them to this host's disk.
        extraConfig = ''
          client_max_body_size 0;
          proxy_request_buffering off;
          proxy_buffering off;
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
        '';
      };
    };
  };
}
