# Host registry — single source of truth for all deployed hosts.
# To add a new host: add an entry here, create hosts/<name>/default.nix.
# Fields:
#   system      — nixpkgs system string for this host (used for nixosSystem/deploy activation)
#   status      — support lifecycle: "active", "inactive", or "legacy-supported"
#   deploy      — presence generates a deploy-rs node; absence = local-only (main)
#   tailnetFQDN — per-host Tailscale FQDN; passed via hostMeta specialArg to host configs
#                 and used by the ACL generator for host-specific destinations when needed
#   tailscale   — Tailscale metadata; presence means host is on the tailnet
#     .tag        — Tailscale tag assigned to this host (without "tag:" prefix)
#     .acceptFrom — source-tag -> allowed inbound ports (TCP+UDP) on this host
#   homeManager — primary-user Home Manager mapping for this host
#     .role     — entrypoint module under home/users/user
#     .profiles — extra profile modules under home/profiles
#     .enableSpotify — whether to include the proprietary Spotify package
#   backup      — drives modules/nixos/profiles/backup.nix retention policy
#     .class    — "critical" (14d/8w/6m/2y) | "standard" (7d/4w/3m); absent = no backup module
#     .name     — restic backup job name; defaults to "local"
#   hardware    — host-local hardware identifiers
#     .diskById — stable /dev/disk/by-id/* path for the primary disk (consumed by disko)
let
  knownFields = [
    "system"
    "status"
    "deploy"
    "tailnetFQDN"
    "tailscale"
    "homeManager"
    "backup"
    "hardware"
  ];

  knownHomeManagerRoles = [
    "desktop"
    "server"
  ];

  knownStatuses = [
    "active"
    "inactive"
    "legacy-supported"
  ];

  knownHomeManagerProfiles = [
    "desktop"
  ];

  knownHomeManagerPacks = [
    "browsing"
    "coding"
    "latex"
    "learning"
  ];

  ok = cond: msg: if cond then true else throw msg;

  validateHost =
    name: cfg:
    let
      p = n: builtins.hasAttr n cfg;

      unknownFields = builtins.filter (k: !builtins.elem k knownFields) (builtins.attrNames cfg);

      checks = [
        (ok (
          unknownFields == [ ]
        ) "${name}: unknown field(s): ${builtins.concatStringsSep ", " unknownFields}")
        (ok (p "system") "${name}: missing required field 'system'")
        (ok (builtins.isString cfg.system) "${name}.system: must be a string, got ${
          builtins.typeOf (cfg.system or null)
        }")
        (ok (p "status") "${name}: missing required field 'status'")
        (ok (builtins.elem (cfg.status or null) knownStatuses)
          "${name}.status: expected one of ${builtins.toJSON knownStatuses}, got ${
            builtins.toJSON (cfg.status or null)
          }"
        )
        (ok (
          !p "deploy"
          || (builtins.isAttrs cfg.deploy && cfg.deploy ? sshUser && builtins.isString cfg.deploy.sshUser)
        ) "${name}.deploy.sshUser: must be a string")
        (ok (
          !p "tailnetFQDN" || builtins.isString cfg.tailnetFQDN
        ) "${name}.tailnetFQDN: must be a string, got ${builtins.typeOf (cfg.tailnetFQDN or null)}")
        (ok
          (
            !p "tailscale"
            || (
              builtins.isAttrs cfg.tailscale
              && cfg.tailscale ? tag
              && builtins.isString cfg.tailscale.tag
              && (
                !cfg.tailscale ? acceptFrom
                || (
                  builtins.isAttrs cfg.tailscale.acceptFrom
                  && builtins.all (
                    ports:
                    builtins.isList ports && builtins.all (port: builtins.isInt port && port > 0 && port < 65536) ports
                  ) (builtins.attrValues cfg.tailscale.acceptFrom)
                )
              )
            )
          )
          "${name}.tailscale: expected tag string and optional acceptFrom attrset of ports (1-65535, TCP+UDP)"
        )
        (ok
          (
            !p "homeManager"
            || (
              builtins.isAttrs cfg.homeManager
              && builtins.elem (cfg.homeManager.role or null) knownHomeManagerRoles
              && (
                !cfg.homeManager ? profiles
                || (
                  builtins.isList cfg.homeManager.profiles
                  && builtins.all builtins.isString cfg.homeManager.profiles
                  && builtins.all (profile: builtins.elem profile knownHomeManagerProfiles) cfg.homeManager.profiles
                )
              )
              && (!cfg.homeManager ? enableSpotify || builtins.isBool cfg.homeManager.enableSpotify)
              && (
                !cfg.homeManager ? packs
                || (
                  builtins.isList cfg.homeManager.packs
                  && builtins.all builtins.isString cfg.homeManager.packs
                  && builtins.all (pack: builtins.elem pack knownHomeManagerPacks) cfg.homeManager.packs
                )
              )
            )
          )
          "${name}.homeManager: expected role in ${builtins.toJSON knownHomeManagerRoles}, profiles from ${builtins.toJSON knownHomeManagerProfiles}, and packs from ${builtins.toJSON knownHomeManagerPacks}"
        )
        (ok
          (
            !p "backup"
            || (
              builtins.isAttrs cfg.backup
              && builtins.elem (cfg.backup.class or null) [
                "critical"
                "standard"
              ]
              && (!cfg.backup ? name || (builtins.isString cfg.backup.name && cfg.backup.name != ""))
            )
          )
          "${name}.backup: expected class \"critical\" or \"standard\" and optional non-empty string name, got ${
            builtins.toJSON (cfg.backup.class or null)
          }"
        )
        (ok (
          !p "hardware"
          || (
            builtins.isAttrs cfg.hardware
            && (!cfg.hardware ? diskById || builtins.isString cfg.hardware.diskById)
          )
        ) "${name}.hardware: expected attrset with optional diskById string")
      ];

      _valid = builtins.foldl' (a: b: a && b) true checks;
    in
    builtins.seq _valid cfg;

  raw = {
    main = {
      system = "x86_64-linux";
      status = "active";
      homeManager = {
        role = "desktop";
        profiles = [ "desktop" ];
        enableSpotify = true;
        packs = [
          "browsing"
          "coding"
          "latex"
          "learning"
        ];
      };
      tailnetFQDN = "main.tail90fc7a.ts.net";
      tailscale = {
        tag = "workstation";
        acceptFrom.workstation = [
          22
          24800
          47984
          47989
          48010
          47998
          47999
          48000
          48002 # Sunshine A/V UDP streams
        ];
      };
      backup.class = "standard";
      hardware.diskById = "/dev/disk/by-id/nvme-eui.0025388401c2aa47";
    };

    homeserver-gcp = {
      system = "x86_64-linux";
      status = "active";
      homeManager.role = "server";
      tailnetFQDN = "homeserver-gcp.tail90fc7a.ts.net";
      backup = {
        class = "critical";
        name = "b2";
      };
      tailscale = {
        tag = "server";
        acceptFrom.workstation = [
          22
          443
          53 # AdGuard DNS
          3001 # AdGuard web UI
        ];
      };
      deploy.sshUser = "user";
    };

    # On-demand GCP Nix remote builder. Normally powered off; `main` starts it
    # transparently for heavy builds and it shuts itself down when idle. No
    # backup (disposable), no homeManager (headless build box). n2 family +
    # nested virtualization so it can run the KVM-backed nixos test suite.
    gcp-builder = {
      system = "x86_64-linux";
      status = "active";
      tailnetFQDN = "gcp-builder.tail90fc7a.ts.net";
      tailscale = {
        tag = "server";
        acceptFrom.workstation = [ 22 ];
      };
      deploy.sshUser = "user";
    };

    # 2017 MacBook Air (A1466) repurposed as a companion workstation.
    # Canonical state lives on `main`; mac syncs via Syncthing, so no backup class.
    # Heaviest packs (latex, learning) are dropped to keep the 128 GB SSD usable;
    # the workstation dev-tool block from home.nix is preserved.
    mac = {
      system = "x86_64-linux";
      status = "active";
      homeManager = {
        role = "desktop";
        profiles = [ "desktop" ];
        enableSpotify = false;
        packs = [
          "browsing"
          "coding"
        ];
      };
      tailnetFQDN = "mac.tail90fc7a.ts.net";
      tailscale = {
        tag = "workstation";
        acceptFrom.workstation = [
          22
          22000
        ];
      };
      deploy.sshUser = "user";
      hardware.diskById = "/dev/disk/by-id/ata-APPLE_SSD_SM0128G_S2XUNY4M230628";
    };

  };
in
builtins.mapAttrs validateHost raw
