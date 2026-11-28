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
#     .exitNodeCanProvide — optional; true makes the host advertise itself as an
#                    exit node (IP forwarding, ACL auto-approval). Devices
#                    still opt in from their Tailscale client; false when omitted
#     .exitNodeUse — optional host name selected as this host's exit node;
#                    lib/invariants.nix rejects it so exit nodes stay opt-in
#   homeManager — primary-user Home Manager mapping for this host
#     .role     — entrypoint module under home/users/user; host additions live
#                 in home/users/user/<host>.nix
#   backup      — drives modules/nixos/profiles/backup.nix retention policy
#     .class    — "critical" (14d/8w/6m/2y) | "standard" (7d/4w/3m); absent = no backup module
#     .name     — restic backup job name; defaults to "local"
#     .restoreTest  — host runs a restore canary that stamps its timestamp; defaults to false
#     .restoreDrill — host runs a full-service restore drill that stamps its timestamp;
#                     defaults to false
#                 lib/backup-evidence.nix turns these into the timestamps the
#                 BackupEvidenceMissing alert expects from each active host
#   dnsServer   — true on the one active host whose AdGuard Home is the tailnet
#                 DNS nameserver (exactly one; lib/invariants.nix checks its grants)
#   sops        — whether this host should have host-secret SOPS coverage; defaults to true
#   remoteBuilder — presence means other hosts offload Nix builds to this one
#     .maxJobs           — concurrent remote jobs callers pass in `--builders`
#     .speedFactor       — `--builders` speed factor
#     .supportedFeatures — this host's nix.settings.system-features, also
#                          advertised by callers in `--builders`
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
      homeManager.role = "desktop";
      tailnetFQDN = "main.${tailnetDomain}";
      tailscale = {
        tag = "workstation";
        ip4 = "100.111.88.61";
        acceptFrom = {
          workstation = [ 22 ];
          # KDE Connect from the phone: 1716 for the link, 1739-1764 for file
          # transfers. Its UDP discovery broadcast doesn't cross the tailnet, so
          # the phone adds this host by its tailnet IP. An untagged phone on the
          # admin's account already passes the break-glass rule; tagging it
          # tag:phone confines it to these ports (plus the opt-in exit node
          # on homeserver-gcp, granted in flake.nix's tailnetAcl).
          phone = [ 1716 ] ++ builtins.genList (i: 1739 + i) 26;
        };
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
        # hosts/homeserver-gcp/backups.nix (daily restore canary) and
        # restore-drill.nix (quarterly full-service drill).
        restoreTest = true;
        restoreDrill = true;
      };
      # AdGuard Home here is the tailnet-wide global DNS nameserver.
      dnsServer = true;
      tailscale = {
        tag = "server";
        # A rebuilt host joins with a new address. The tailnet's global DNS
        # nameserver override points here too and must be changed to match.
        ip4 = "100.73.57.109";
        # Opt-in exit node: nothing routes through it until a device picks it
        # in its Tailscale client. Exit traffic is forwarded, not delivered to
        # this host, so it needs no acceptFrom port or tailscale0 opening.
        exitNodeCanProvide = true;
        acceptFrom = {
          workstation = [
            22
            443
            53 # AdGuard DNS
            3001 # AdGuard web UI
          ];
          # gcp-builder has no other resolver: AdGuard is the tailnet-wide
          # global nameserver, so without DNS it cannot resolve cache.nixos.org
          # and every offloaded closure build stalls on cache lookups.
          builder = [ 53 ];
          # External CI runners use a pre-approved tag and only need SSH for
          # the homeserver's CI maintenance/deployment surface.
          ci = [ 22 ];
        };
      };
      deploy.sshUser = "user";
    };

    # On-demand GCP Nix remote builder. Normally powered off; `main` starts it
    # transparently for heavy builds and it shuts itself down when idle. It
    # also runs `on-worker` batch jobs as the unprivileged `jobs` user, which
    # resolve PyPI through the homeserver's `builder` DNS grant above. No
    # backup (disposable), no homeManager (headless build box). n2 family +
    # nested virtualization so it can run the KVM-backed nixos test suite.
    gcp-builder = {
      system = "x86_64-linux";
      status = "active";
      tailnetFQDN = "gcp-builder.${tailnetDomain}";
      tailscale = {
        tag = "builder";
        # CI's tag:ci-builder cannot reach the tailnet resolver, so the
        # workflows address the builder by this IP (BUILDER_FQDN), and
        # invariants-gcp-builder fails if they drift. Reprovisioning changes it.
        ip4 = "100.106.144.121";
        acceptFrom = {
          workstation = [ 22 ];
          # GitHub runners run CI on this host. A separate tag from `ci`, which
          # can also reach the homeserver.
          ci-builder = [ 22 ];
        };
      };
      deploy.sshUser = "user";
      # Read by this host's system-features, `nixos-switch-main --remote` and
      # scripts/lib/builder.sh. 14 jobs for the 14 vCPUs; kvm needs the VM's
      # nested virtualization (n2 family).
      remoteBuilder = {
        maxJobs = 14;
        speedFactor = 2;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
      };
      sops = false;
    };

  };
in
hostRegistryLib.validateRegistry raw
