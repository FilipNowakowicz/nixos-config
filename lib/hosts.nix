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
#     .ip4        — this host's stable 100.x.x.x Tailscale IPv4 address (per
#                    node-key); used by consumers (e.g. AdGuard clients) that
#                    need a literal IP rather than a resolvable FQDN
#     .advertisedRoutes / .acceptedRoutes — optional explicit CIDR route lists
#     .exitNodeCanProvide — optional capability flag; false when omitted
#     .exitNodeUse — optional host name selected as this host's exit node
#   homeManager — primary-user Home Manager mapping for this host
#     .role     — entrypoint module under home/users/user
#     .profiles — extra profile modules under home/profiles
#     .enableSpotify — whether to include the proprietary Spotify package
#   backup      — drives modules/nixos/profiles/backup.nix retention policy
#     .class    — "critical" (14d/8w/6m/2y) | "standard" (7d/4w/3m); absent = no backup module
#     .name     — restic backup job name; defaults to "local"
#   sops        — whether this host should have host-secret SOPS coverage; defaults to true
#   hardware    — host-local hardware identifiers
#     .diskById — stable /dev/disk/by-id/* path for the primary disk (consumed by disko)
let
  hostRegistryLib = import ./host-registry.nix;

  # Single source of truth for the tailnet domain; each host's tailnetFQDN is
  # derived as "${name}.${tailnetDomain}" so a tailnet rename is one line.
  tailnetDomain = "tail90fc7a.ts.net";

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
      tailnetFQDN = "main.${tailnetDomain}";
      tailscale = {
        tag = "workstation";
        ip4 = "100.111.88.61";
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
      tailnetFQDN = "homeserver-gcp.${tailnetDomain}";
      backup = {
        class = "critical";
        name = "b2";
      };
      tailscale = {
        tag = "server";
        # Re-registered to .88 after a forced tailnet re-join on 2026-06-21
        # (the .89 device was deleted upstream; Tailscale assigns the lowest
        # free IP, and .88 < .89, so .89 is unreclaimable). The tailnet global
        # DNS nameserver override was repointed to .88 to match.
        ip4 = "100.103.234.88";
        acceptFrom = {
          workstation = [
            22
            443
            53 # AdGuard DNS
            3001 # AdGuard web UI
          ];
          # gcp-agent has no other resolver: AdGuard is the tailnet-wide global
          # nameserver, so without this `gh`/`claude` on gcp-agent cannot
          # resolve any external hostname (DNS queries time out).
          agent = [ 53 ];
          # gcp-builder is in the same bind: AdGuard is its only resolver, so
          # without DNS it cannot resolve cache.nixos.org and every offloaded
          # closure build stalls on cache lookups. Grant tag:builder -> :53.
          builder = [ 53 ];
        };
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
      tailnetFQDN = "gcp-builder.${tailnetDomain}";
      tailscale = {
        tag = "builder";
        acceptFrom.workstation = [ 22 ];
        # gcp-agent offloads heavy builds here too (its own dedicated build
        # key, see hosts/gcp-agent/nix-remote-build.nix).
        acceptFrom.agent = [ 22 ];
      };
      deploy.sshUser = "user";
      sops = false;
    };

    # On-demand GCP host for running Claude Code sessions (issue-loop
    # orchestration), not Nix builds. Normally powered off; started for a
    # session and self-powers-off when idle (see hosts/gcp-agent). Unlike
    # gcp-builder it carries secrets (sops = default true): its own claude
    # login and a scoped GitHub PAT for branch push + PR creation. Disposable:
    # state is a repo clone + nix store, recoverable by reprovisioning, so no
    # backup. Heavy builds/tests offload to gcp-builder, so no nested virt
    # requirement — e2 family is fine.
    gcp-agent = {
      system = "x86_64-linux";
      status = "active";
      homeManager.role = "agent";
      tailnetFQDN = "gcp-agent.${tailnetDomain}";
      tailscale = {
        tag = "agent";
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
      tailnetFQDN = "mac.${tailnetDomain}";
      tailscale = {
        tag = "workstation";
        ip4 = "100.73.117.103";
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
hostRegistryLib.validateRegistry raw
