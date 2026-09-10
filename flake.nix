{
  description = "NixOS and Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    home-manager = {
      # Pair with the nixpkgs channel: nixos-unstable tracks Home Manager
      # `master`, a stable nixpkgs release branch tracks the matching
      # `release-XX.YY`. Mismatching them triggers HM release-version warnings.
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
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
      deploy-rs,
      nixos-anywhere,
      pre-commit-hooks,
      treefmt-nix,
      ...
    }:
    let
      defaultSystem = "x86_64-linux";

      lazyactionsOverlay = _: prev: {
        lazyactions = prev.buildGoModule {
          pname = "lazyactions";
          version = "unstable";
          src = prev.fetchFromGitHub {
            owner = "nnnkkk7";
            repo = "lazyactions";
            rev = "7058157e1ac3723c905cf2f9bf0138f8ebfb4465";
            hash = "sha256-2y4jmuCBe6HDpn2tj9YMAHNBx46z/LsmMoPOWAGkbAk=";
          };
          vendorHash = "sha256-cDLLpU0xsv57yE2cOMddcf2/mHsmGAe69pbNYGSL1XE=";
          subPackages = [ "cmd/lazyactions" ];
        };
      };

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

      # SIP 6.16.1 made `%MinimumABIVersion` mandatory: a binding that targets a
      # legacy ABI (major <= 13) without declaring the directive is now rejected
      # outright. PyQt5 5.15.10 asks for ABI 12.13 in its `project.py` but ships
      # no `%MinimumABIVersion` in any of its module specs, so every PyQt5
      # module fails to generate with "ABI v12 is being targeted but the
      # PyQt5.QtCore module doesn't support it". That breaks `main` through
      # texlive's Asymptote, which is why CI's `main-ci` variant
      # (`skipHeavyPackages = true`) stays green.
      #
      # Upstream SIP fixed the regression in 09598895 (Python-SIP/sip#114) and
      # nixpkgs backported it in 60e5dfae, but that has not reached the
      # nixos-unstable channel yet. Patching SIP rather than PyQt5 keeps us on
      # the upstream fix and covers every legacy-ABI consumer (poppler-qt5,
      # qgis, ...) instead of just the module the error happened to name.
      #
      # Remove this overlay once `flake.lock` advances past nixpkgs 60e5dfae;
      # `checks.sip-legacy-abi-overlay-still-needed` fails when it becomes
      # redundant.
      sipLegacyAbiOverlay = final: prev: {
        pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ]) ++ [
          (_: pyPrev: {
            sip = pyPrev.sip.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [
                (final.fetchpatch {
                  name = "sip-legacy-abi-minimumabiversion.patch";
                  url = "https://github.com/Python-SIP/sip/commit/09598895c607f3e41f0249ade217ace0a4da6437.patch";
                  hash = "sha256-v0YeHyg0ymB0v32gpVRbMBIUk9U2etjs93VuOGPGg2M=";
                })
              ];
            });
          })
        ];
      };

      hostRegistry = import ./lib/hosts.nix;

      inherit (nixpkgs) lib;

      pkgsHelper = import ./flake/pkgs.nix {
        inherit nixpkgs;
        overlays = [
          lazyactionsOverlay
          libfprintGoodixOverlay
          sipLegacyAbiOverlay
        ];
      };
      inherit (pkgsHelper) mkPkgs overlays;

      pkgs = mkPkgs { system = defaultSystem; };

      invariants = import ./lib/invariants.nix { inherit lib pkgs; };
      aclGen = import ./lib/acl.nix { inherit lib; };

      hostOutputs = import ./flake/hosts.nix {
        inherit
          inputs
          self
          nixpkgs
          lib
          hostRegistry
          mkPkgs
          overlays
          ;
        inherit (inputs)
          home-manager
          sops-nix
          ;
      };

      inherit (hostOutputs)
        allNixosConfigs
        ciNixosConfigs
        homeConfigurations
        ;

      deployOutputs = import ./flake/deploy.nix {
        inherit
          deploy-rs
          lib
          hostRegistry
          allNixosConfigs
          ciNixosConfigs
          ;
      };

      inherit (deployOutputs)
        allDeployNodes
        ciDeployNodes
        ;

      checkOutputs = import ./flake/checks.nix {
        inherit
          lib
          pkgs
          nixpkgs
          inputs
          hostRegistry
          allNixosConfigs
          ciNixosConfigs
          invariants
          ;
      };

      inherit (checkOutputs)
        ciTestsFor
        invariantChecks
        ;
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ defaultSystem ];

      perSystem =
        { system, self', ... }:
        let
          pkgs = mkPkgs { inherit system; };
        in
        import ./flake/dev.nix {
          inherit
            lib
            pkgs
            system
            nixpkgs
            pre-commit-hooks
            treefmt-nix
            hostRegistry
            ciNixosConfigs
            aclGen
            deploy-rs
            nixos-anywhere
            ciDeployNodes
            invariantChecks
            self'
            ;
          flakeInputs = inputs;
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
        };

        # ── Home Manager Configurations ─────────────────────────────────────
        inherit homeConfigurations;

        # ── Reusable pure-function libraries ────────────────────────────────
        # Identifier-free helper libraries that evaluate with stock
        # `nixpkgs.lib` and no fleet context, so they can be imported into a
        # separate flake. Boundary tests (`lib-dashboards`, `lib-generators`)
        # prove they build outside the personal host assembly. See
        # `docs/modules/lib-helpers.md`.
        lib = {
          acl = aclGen;
          dashboards = import ./lib/dashboards.nix;
          generators = import ./lib/generators.nix { inherit lib; };
        };

        # ── Modules ─────────────────────────────────────────────────────────
        nixosModules = {
          observability-stack = import ./modules/nixos/profiles/observability;
          observability-client = import ./modules/nixos/profiles/observability-client.nix;
          services-hardened = import ./modules/nixos/services/hardened.nix;
          profiles-base = import ./modules/nixos/profiles/base.nix;
          profiles-desktop = import ./modules/nixos/profiles/desktop.nix;
          profiles-security = import ./modules/nixos/profiles/security.nix;
        };

        homeModules = {
          neovim = import ./home/neovim/module.nix;
          profiles-base = import ./home/profiles/base.nix;
          profiles-desktop = import ./home/profiles/desktop.nix;
          profiles-workflow-packs = import ./home/profiles/workflow-packs;
          runtime-theme = import ./home/theme/module.nix;
        };
      };
    };
}
