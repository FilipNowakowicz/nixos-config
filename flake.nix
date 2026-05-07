{
  description = "NixOS and Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.follows = "nixos-anywhere/flake-parts";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence.url = "github:nix-community/impermanence";

    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      home-manager,
      deploy-rs,
      nixos-anywhere,
      sops-nix,
      pre-commit-hooks,
      treefmt-nix,
      ...
    }:
    let
      defaultSystem = "x86_64-linux";

      libfprintGoodixOverlay =
        final: prev:
        let
          rev = "882735c6366fbe30149eea5cfd6d0ddff880f0e4";
        in
        {
          libfprint-2-tod1-goodix = prev.libfprint-2-tod1-goodix.overrideAttrs (_: {
            # Launchpad has become intermittently unreachable during builds.
            # Use a fixed GitHub mirror for the same upstream revision instead.
            src = final.fetchFromGitHub {
              owner = "hadess";
              repo = "libfprint-2-tod1-goodix";
              inherit rev;
              hash = "sha256-Uv+Rr4V31DyaZFOj79Lpyfl3G6zVWShh20roI0AvMPU=";
            };
          });
        };

      hostRegistry = import ./lib/hosts.nix;

      pkgs = import nixpkgs {
        system = defaultSystem;
        config.allowUnfree = true;
        overlays = [ libfprintGoodixOverlay ];
      };

      inherit (nixpkgs) lib;

      homeManagerRoleModules = {
        desktop = ./home/users/user/home.nix;
        server = ./home/users/user/server.nix;
      };

      homeManagerProfileModules = {
        desktop = ./home/profiles/desktop.nix;
        workstation = ./home/profiles/workstation.nix;
      };

      mkHomeManagerImports =
        hostMeta:
        let
          hm = hostMeta.homeManager;
          enabledPacks = hm.packs or [ ];
          workflowPackModule = {
            config = lib.mkMerge (
              map (pack: lib.setAttrByPath [ "workflowPacks" pack "enable" ] true) enabledPacks
            );
          };
        in
        [ homeManagerRoleModules.${hm.role} ]
        ++ map (profile: homeManagerProfileModules.${profile}) (hm.profiles or [ ])
        ++ lib.optional (enabledPacks != [ ]) workflowPackModule;

      invariants = import ./lib/invariants.nix { inherit lib pkgs; };

      aclGen = import ./lib/acl.nix { inherit lib; };

      # VMs only — for the VM management script
      vmRegistry = lib.filterAttrs (_: cfg: cfg ? sshPort && cfg ? diskSize) hostRegistry;

      mkNixos =
        host: variantArgs:
        let
          hostMeta = hostRegistry.${host};
          extraModules = variantArgs.extraModules or [ ];
          homeManagerExtraArgs = builtins.removeAttrs variantArgs [ "extraModules" ];
        in
        nixpkgs.lib.nixosSystem {
          inherit (hostMeta) system;
          specialArgs = {
            inherit
              inputs
              self
              hostMeta
              hostRegistry
              ;
          };
          modules = [
            ./hosts/${host}/default.nix
            home-manager.nixosModules.home-manager
            sops-nix.nixosModules.sops
            {
              nixpkgs.overlays = [ libfprintGoodixOverlay ];
            }
            {
              imports = [ ./modules/nixos ];
            }
            (lib.mkIf (hostMeta ? homeManager) {
              home-manager.users.user.imports = mkHomeManagerImports hostMeta;
            })
            {
              home-manager.extraSpecialArgs = {
                skipHeavyPackages = false;
                enableSpotify = hostMeta.homeManager.enableSpotify or true;
              }
              // homeManagerExtraArgs;
            }
          ]
          ++ extraModules;
        };

      # ── Host-derived infrastructure ──────────────────────────────────────
      allNixosConfigs = lib.mapAttrs (name: _: mkNixos name { }) hostRegistry;

      ciNixosConfigs = allNixosConfigs // {
        main-ci = mkNixos "main" {
          skipHeavyPackages = true;
          extraModules = [
            (
              { lib, ... }:
              {
                services.fprintd.enable = lib.mkForce false;
              }
            )
          ];
        };

        vm-ci = mkNixos "vm" {
          skipHeavyPackages = true;
        };

        homeserver-gcp = mkNixos "homeserver-gcp" {
          extraModules = [
            (
              { lib, modulesPath, ... }:
              {
                # google-compute-config.nix calls readFile on google-guest-configs at
                # eval time, requiring the package to exist in the Nix store. Disable
                # it for flake check; it is still active on real deployments via
                # hardware-configuration.nix → google-compute-image.nix.
                # Must use modulesPath (absolute store path) since the module is
                # imported as a path, not a string, so the key won't match a string.
                disabledModules = [ "${modulesPath}/virtualisation/google-compute-config.nix" ];

                # Stub out the required options that google-compute-config.nix
                # normally provides so NixOS module assertions pass.
                fileSystems."/" = lib.mkDefault {
                  device = "/dev/disk/by-label/nixos";
                  fsType = "ext4";
                };
                boot.loader.grub.device = lib.mkDefault "/dev/sda";
              }
            )
          ];
        };
      };

      deployableHosts = lib.filterAttrs (_: cfg: cfg ? deploy) hostRegistry;

      mkDeployNodes =
        nixosConfigs:
        lib.mapAttrs (name: cfg: {
          hostname = name;
          inherit (cfg.deploy) sshUser;
          magicRollback = true;
          autoRollback = true;
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.${cfg.system}.activate.nixos nixosConfigs.${name};
          };
        }) deployableHosts;

      allDeployNodes = mkDeployNodes ciNixosConfigs;

      ciDeployNodes = mkDeployNodes (
        ciNixosConfigs
        // {
          vm = ciNixosConfigs.vm-ci;
        }
      );

      # ── Configuration Invariant Checks ──────────────────────────────────
      invariantChecks =
        let
          mkResult = passed: message: {
            inherit passed message;
          };

          require = condition: message: mkResult condition message;

          requirePaths =
            actual: expected:
            let
              missing = lib.filter (path: !(builtins.elem path actual)) expected;
            in
            mkResult (missing == [ ]) "missing expected path(s): ${lib.concatStringsSep ", " missing}";

          invalidInitrdSecrets =
            cfg:
            let
              values = lib.attrValues cfg.boot.initrd.secrets;
              nonNull = lib.filter (v: v != null) values;
            in
            lib.filter (v: !lib.hasPrefix "/run/secrets/" v) nonNull;

          registryAssertionsFor = hostName: invariants.mkRegistryAssertions hostName hostRegistry.${hostName};

          sshFail2banHardened = {
            name = "SSH hosts enforce hardened fail2ban";
            check =
              cfg:
              let
                violations = lib.filter (msg: msg != "") [
                  (lib.optionalString (!cfg.services.fail2ban.enable) "services.fail2ban.enable must be true")
                  (lib.optionalString (cfg.services.fail2ban.maxretry > 3) "services.fail2ban.maxretry must be <= 3")
                  (lib.optionalString (
                    cfg.services.fail2ban.bantime != "30m"
                  ) "services.fail2ban.bantime must be \"30m\"")
                  (lib.optionalString (
                    !cfg.services.fail2ban."bantime-increment".enable
                  ) "services.fail2ban.bantime-increment.enable must be true")
                  (lib.optionalString (
                    cfg.services.fail2ban."bantime-increment".maxtime == null
                  ) "services.fail2ban.bantime-increment.maxtime must be set")
                ];
              in
              if !cfg.services.openssh.enable then
                mkResult true "services.openssh.enable is false"
              else
                mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
          };

          obsClientUsesCanonicalUsername = {
            name = "observability client uses canonical ingest username";
            check =
              cfg:
              let
                clientEnabled = cfg.profiles.observability-client.enable;
                inherit (cfg.profiles.observability.ingestAuth) username;
              in
              require (
                !clientEnabled || username == "telemetry"
              ) "profiles.observability.ingestAuth.username must be 'telemetry', got '${username}'";
          };

          mainSshIsTailnetOnly = {
            name = "main SSH stays tailnet-only";
            check =
              cfg:
              let
                violations = lib.filter (msg: msg != "") [
                  (lib.optionalString (!cfg.services.openssh.enable) "services.openssh.enable must be true")
                  (lib.optionalString cfg.services.openssh.openFirewall "services.openssh.openFirewall must be false")
                  (lib.optionalString (!cfg.services.tailscale.enable) "services.tailscale.enable must be true")
                  (lib.optionalString (
                    !cfg.services.tailscale.openFirewall
                  ) "services.tailscale.openFirewall must be true")
                ];
              in
              mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
          };

          mainUsbguardIsDenyDefault = {
            name = "main USBGuard stays deny-default";
            check =
              cfg:
              let
                rules = cfg.services.usbguard.rules or "";
                violations = lib.filter (msg: msg != "") [
                  (lib.optionalString (!cfg.services.usbguard.enable) "services.usbguard.enable must be true")
                  (lib.optionalString (
                    !lib.hasInfix "allow id " rules
                  ) "services.usbguard.rules must whitelist at least one device")
                  (lib.optionalString (
                    !lib.hasInfix "reject" rules
                  ) "services.usbguard.rules must include a default reject rule")
                ];
              in
              mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
          };

          mainLocalBackupProtectsCriticalPaths = {
            name = "main local backup covers critical operator data";
            check =
              cfg:
              let
                backup = cfg.services.restic.backups.local;
                expectedPaths = [
                  "/home/user/.ssh"
                  "/home/user/.gnupg"
                  "/home/user/nix"
                ];
                pathCheck = requirePaths backup.paths expectedPaths;
                violations = lib.filter (msg: msg != "") [
                  (lib.optionalString (
                    !(lib.hasPrefix "/run/secrets/" (backup.passwordFile or ""))
                  ) "services.restic.backups.local.passwordFile must come from /run/secrets/*")
                  (lib.optionalString (!backup.initialize) "services.restic.backups.local.initialize must be true")
                  (lib.optionalString (
                    (backup.timerConfig.OnCalendar or null) != "daily"
                  ) "services.restic.backups.local.timerConfig.OnCalendar must be \"daily\"")
                  (lib.optionalString (!pathCheck.passed) pathCheck.message)
                ];
              in
              mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
          };

          homeserverGcpB2BackupUsesCriticalPolicy = {
            name = "homeserver-gcp B2 backup uses critical policy";
            check =
              cfg:
              let
                backup = cfg.services.restic.backups.b2;
                expectedPruneOpts = [
                  "--keep-daily 14"
                  "--keep-weekly 8"
                  "--keep-monthly 6"
                  "--keep-yearly 2"
                ];
                pathCheck = requirePaths backup.paths [
                  "/var/lib/vaultwarden"
                  "/var/lib/grafana"
                ];
                violations = lib.filter (msg: msg != "") [
                  (lib.optionalString (
                    backup.repository != "b2:filipnowakowicz-gcp:"
                  ) "services.restic.backups.b2.repository must target filipnowakowicz-gcp")
                  (lib.optionalString (
                    !(lib.hasPrefix "/run/secrets/" (backup.passwordFile or ""))
                  ) "services.restic.backups.b2.passwordFile must come from /run/secrets/*")
                  (lib.optionalString (
                    !(lib.hasPrefix "/run/secrets/" (backup.environmentFile or ""))
                  ) "services.restic.backups.b2.environmentFile must come from /run/secrets/*")
                  (lib.optionalString (!backup.initialize) "services.restic.backups.b2.initialize must be true")
                  (lib.optionalString (
                    backup.pruneOpts != expectedPruneOpts
                  ) "services.restic.backups.b2.pruneOpts must match the critical retention class")
                  (lib.optionalString (
                    (backup.timerConfig.OnCalendar or null) != "daily"
                  ) "services.restic.backups.b2.timerConfig.OnCalendar must be \"daily\"")
                  (lib.optionalString (!pathCheck.passed) pathCheck.message)
                ];
              in
              mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
          };

        in
        {
          invariants-main = invariants.mkInvariantCheck "main" (
            [
              {
                name = "has stateVersion";
                check = cfg: require (cfg.system.stateVersion != null) "system.stateVersion must be set";
              }
              {
                name = "no passwordless sudo";
                check =
                  cfg: require cfg.security.sudo.wheelNeedsPassword "security.sudo.wheelNeedsPassword must be true";
              }
              {
                name = "initrd secrets point to sops-managed paths";
                check =
                  cfg:
                  let
                    invalid = invalidInitrdSecrets cfg;
                  in
                  mkResult (
                    invalid == [ ]
                  ) "boot.initrd.secrets must point to /run/secrets/*, got: ${lib.concatStringsSep ", " invalid}";
              }
              sshFail2banHardened
              obsClientUsesCanonicalUsername
              mainSshIsTailnetOnly
              mainUsbguardIsDenyDefault
              mainLocalBackupProtectsCriticalPaths
            ]
            ++ registryAssertionsFor "main"
          ) allNixosConfigs.main.config;

          invariants-vm = invariants.mkInvariantCheck "vm" (
            [
              {
                name = "has stateVersion";
                check = cfg: require (cfg.system.stateVersion != null) "system.stateVersion must be set";
              }
              {
                name = "passwordless sudo enabled";
                check =
                  cfg:
                  require (!cfg.security.sudo.wheelNeedsPassword) "security.sudo.wheelNeedsPassword must be false";
              }
              sshFail2banHardened
              obsClientUsesCanonicalUsername
            ]
            ++ registryAssertionsFor "vm"
          ) allNixosConfigs.vm.config;

          invariants-homeserver-gcp = invariants.mkInvariantCheck "homeserver-gcp" (
            [
              {
                name = "has stateVersion";
                check = cfg: require (cfg.system.stateVersion != null) "system.stateVersion must be set";
              }
              {
                name = "no passwordless sudo";
                check =
                  cfg: require cfg.security.sudo.wheelNeedsPassword "security.sudo.wheelNeedsPassword must be true";
              }
              {
                name = "firewall enabled";
                check = cfg: require cfg.networking.firewall.enable "networking.firewall.enable must be true";
              }
              {
                name = "nix trusted-users stay root-only";
                check = cfg: invariants.checkExpectedTrustedUsers [ "root" ] cfg;
              }
              {
                name = "SSH and HTTPS are not globally open";
                check = cfg: invariants.checkNoGlobalTCPPorts [ 22 443 ] cfg;
              }
              {
                name = "SSH and HTTPS stay Tailscale-only";
                check =
                  cfg:
                  invariants.checkTCPPortsRestrictedToInterface {
                    interface = "tailscale0";
                    ports = [
                      22
                      443
                    ];
                  } cfg;
              }
              {
                name = "sops uses SSH host key for decryption";
                check =
                  cfg:
                  require (
                    cfg.sops.age.sshKeyPaths != [ ]
                  ) "sops.age.sshKeyPaths must contain at least one SSH host key path";
              }
              sshFail2banHardened
              homeserverGcpB2BackupUsesCriticalPolicy
            ]
            ++ registryAssertionsFor "homeserver-gcp"
          ) ciNixosConfigs.homeserver-gcp.config;

          homeserver-gcp-sops-bootstrap =
            let
              secretsDir = ./hosts/homeserver-gcp/secrets;
              hasKey = builtins.pathExists (secretsDir + "/ssh_host_ed25519_key.enc");
              hasPub = builtins.pathExists (secretsDir + "/ssh_host_ed25519_key.pub.enc");
            in
            if hasKey && hasPub then
              pkgs.runCommand "homeserver-gcp-sops-bootstrap-check" { } "touch $out"
            else
              pkgs.runCommand "homeserver-gcp-sops-bootstrap-check" { } ''
                echo "homeserver-gcp sops bootstrap incomplete — missing pre-baked host key files:"
                ${lib.optionalString (!hasKey) ''echo "  hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.enc"''}
                ${lib.optionalString (
                  !hasPub
                ) ''echo "  hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.pub.enc"''}
                exit 1
              '';

        };

      cveReportPackagesFor =
        system:
        let
          targetPkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          targetCveChecks = import ./lib/cve-checks.nix { pkgs = targetPkgs; };
        in
        {
          main = targetCveChecks.mkCveCheck "main" allNixosConfigs.main.config.system.build.toplevel;
        };

      ciTestsFor = system: {
        vm-smoke = import ./tests/nixos/vm-smoke.nix {
          inherit nixpkgs system inputs;
        };
        homeserver-gcp-smoke = import ./tests/nixos/homeserver-gcp-smoke.nix {
          inherit nixpkgs system inputs;
        };
        profile-security = import ./tests/nixos/profile-security.nix {
          inherit nixpkgs system;
        };
        profile-observability = import ./tests/nixos/profile-observability.nix {
          inherit nixpkgs system;
        };
        profile-hardening = import ./tests/nixos/profile-hardening.nix {
          inherit nixpkgs system;
        };
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ defaultSystem ];

      perSystem =
        { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          # VM management script — unified entry point
          vmApp = {
            type = "app";
            program = toString (
              pkgs.writeShellScript "vm" ''
                export VM_REGISTRY='${builtins.toJSON vmRegistry}'
                export OVMF_CODE="${pkgs.OVMF.fd}/FV/OVMF_CODE.fd"
                export OVMF_SOURCE="${pkgs.OVMF.fd}/FV/OVMF_VARS.fd"
                export QEMU_BIN="${pkgs.qemu}/bin/qemu-system-x86_64"
                export QEMU_IMG_BIN="${pkgs.qemu}/bin/qemu-img"
                export JQ_BIN="${pkgs.jq}/bin/jq"
                export SSH_KEYGEN_BIN="${pkgs.openssh}/bin/ssh-keygen"
                export NIXOS_ANYWHERE_BIN="${nixos-anywhere.packages.${system}.nixos-anywhere}/bin/nixos-anywhere"
                export SOPS_BIN="${pkgs.sops}/bin/sops"
                export SSH_TO_AGE_BIN="${pkgs.ssh-to-age}/bin/ssh-to-age"
                exec ${pkgs.bash}/bin/bash ${./scripts/vm.sh} "$@"
              ''
            );
            meta.description = "Manage QEMU/KVM virtual machines";
          };

          treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

          preCommitCheck = import ./pre-commit-hooks.nix {
            inherit
              pkgs
              pre-commit-hooks
              system
              treefmtEval
              ;
          };

          commitMsgHook = pkgs.writeShellScript "commit-msg-hook" ''
            set -euo pipefail

            # Keep commit attribution single-author unless explicitly rewritten later.
            sed -i '/^Co-authored-by:/Id' "$1"
          '';
        in
        {
          # ── Apps ────────────────────────────────────────────────────────────
          apps = {
            doctor = {
              type = "app";
              program = toString (
                pkgs.writeShellScript "doctor" ''
                  export PATH="${lib.makeBinPath [ pkgs.python3 ]}:$PATH"
                  exec ${pkgs.bash}/bin/bash ${./scripts/doctor.sh} "$@"
                ''
              );
              meta.description = "Run clean-clone documentation, planner, evaluation, and formatting checks";
            };
            vm = vmApp;
          };

          # ── Packages ────────────────────────────────────────────────────────
          packages = {
            inventory = import ./packages/inventory.nix {
              inherit
                lib
                pkgs
                hostRegistry
                ;
              # Use ciNixosConfigs (filtered to registry hosts) so the
              # inventory's evaluation of homeserver-gcp's system.build.toplevel
              # goes through the CI override that disables
              # google-compute-config.nix (readFiles google-guest-configs at
              # eval time). Filter excludes synthetic main-ci/vm-ci keys.
              allNixosConfigs = lib.intersectAttrs hostRegistry ciNixosConfigs;
            };

            tailscale-acl =
              pkgs.runCommand "tailscale-acl"
                {
                  aclJson = builtins.toJSON (aclGen.mkAcl hostRegistry);
                  passAsFile = [ "aclJson" ];
                }
                ''
                  cp "$aclJsonPath" "$out"
                '';

            installer-iso =
              (nixpkgs.lib.nixosSystem {
                inherit system;
                specialArgs = { inherit inputs; };
                modules = [ ./hosts/installer/default.nix ];
              }).config.system.build.isoImage;

          };

          # ── Formatter ───────────────────────────────────────────────────────
          formatter = treefmtEval.config.build.wrapper;

          # ── Shells ──────────────────────────────────────────────────────────
          devShells = {
            default = pkgs.mkShell {
              packages =
                (with pkgs; [
                  nixd
                  statix
                  deadnix
                  sops
                  ssh-to-age
                  qemu
                  OVMF
                  python3
                  vulnix
                  direnv
                  opentofu
                  google-cloud-sdk
                ])
                ++ [
                  deploy-rs.packages.${system}.deploy-rs
                  nixos-anywhere.packages.${system}.nixos-anywhere
                ]
                ++ preCommitCheck.enabledPackages;
              shellHook = ''
                ${preCommitCheck.shellHook}
                common_git_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
                if [ -n "$common_git_dir" ]; then
                  ${pkgs.coreutils}/bin/install -Dm755 ${commitMsgHook} "$common_git_dir/hooks/commit-msg"
                fi
                # Make 'vm' command available directly in the dev shell
                alias vm="nix run '.#vm' --"
                exec ${pkgs.zsh}/bin/zsh
              '';
            };

            security = pkgs.mkShell {
              packages = with pkgs; [
                nmap
                whois
                dnsutils
                sqlmap
                gobuster
                ffuf
                hydra
                john
                hashcat
                netcat-gnu
                wireshark-cli
              ];
              shellHook = ''
                	echo "Security tools ready"
                	echo ""
                	echo "Available tools:"
                	echo "  Network:   nmap, whois, dig, netcat"
                	echo "  Web:       sqlmap, gobuster, ffuf"
                	echo "  Password:  hydra, john, hashcat"
                	echo "  Analysis:  wireshark-cli (tshark)"
                	exec ${pkgs.zsh}/bin/zsh
              '';
            };
          };

          checks =
            deploy-rs.lib.${system}.deployChecks { nodes = ciDeployNodes; }
            // invariantChecks
            // {
              lib-generators = import ./tests/lib/generators.nix {
                inherit nixpkgs system;
              };
              lib-generators-golden = import ./tests/lib/generators.golden.nix {
                inherit nixpkgs system;
              };
              lib-acl = import ./tests/lib/acl.nix {
                inherit nixpkgs system;
              };
              lib-invariants = import ./tests/lib/invariants.nix {
                inherit nixpkgs system;
              };
              secrets-directory = import ./tests/lib/secrets-directory.nix {
                inherit nixpkgs system;
              };
            };

        };

      flake = {
        # ── NixOS Configurations ────────────────────────────────────────────
        nixosConfigurations = ciNixosConfigs;

        # ── Deploy-RS ───────────────────────────────────────────────────────
        deploy.nodes = allDeployNodes;

        # ── CI-only derivations ─────────────────────────────────────────────
        # Keep these out of `packages` and `checks`: `nix flake check` inspects
        # both outputs, which defeats path-gating and can trip VM-test eval.
        legacyPackages.${defaultSystem} = {
          ciTests = ciTestsFor defaultSystem;
          ciReports = cveReportPackagesFor defaultSystem;
        };

        # ── Home Manager Configurations ─────────────────────────────────────
        homeConfigurations = {
          user = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            extraSpecialArgs = {
              inherit inputs;
              skipHeavyPackages = false;
              enableSpotify = true;
            };
            modules = [
              ./home/users/user/home.nix
            ];
          };
          "user@wsl" = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            extraSpecialArgs = {
              inherit inputs;
              skipHeavyPackages = false;
              enableSpotify = true;
            };
            modules = [
              ./home/users/user/wsl.nix
            ];
          };
        };

        # ── Templates ───────────────────────────────────────────────────────
        templates.python = {
          path = ./templates/python;
          description = "Python dev shell with uv, ruff, and basedpyright";
        };

        # ── Modules ─────────────────────────────────────────────────────────
        nixosModules = {
          profiles-base = import ./modules/nixos/profiles/base.nix;
          profiles-desktop = import ./modules/nixos/profiles/desktop.nix;
          profiles-observability = import ./modules/nixos/profiles/observability;
          profiles-security = import ./modules/nixos/profiles/security.nix;
          profiles-vm = import ./modules/nixos/profiles/vm.nix;
        };

        homeModules = {
          neovim = import ./home/neovim/module.nix;
          profiles-base = import ./home/profiles/base.nix;
          profiles-desktop = import ./home/profiles/desktop.nix;
          profiles-workflow-packs = import ./home/profiles/workflow-packs;
          profiles-workstation = import ./home/profiles/workstation.nix;
        };
      };
    };
}
