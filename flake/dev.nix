{
  lib,
  pkgs,
  system,
  nixpkgs,
  pre-commit-hooks,
  treefmt-nix,
  hostRegistry,
  ciNixosConfigs,
  aclGen,
  deploy-rs,
  nixos-anywhere,
  flakeInputs,
  ciDeployNodes,
  invariantChecks,
  self',
}:
let
  controlCenterPackage = pkgs.callPackage ../packages/control-center { };

  tailscaleAclPackage =
    pkgs.runCommand "tailscale-acl"
      {
        aclJson = builtins.toJSON (aclGen.mkAcl hostRegistry);
        passAsFile = [ "aclJson" ];
      }
      ''
        cp "$aclJsonPath" "$out"
      '';

  treefmtEval = treefmt-nix.lib.evalModule pkgs ../treefmt.nix;

  preCommitCheck = import ../pre-commit-hooks.nix {
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
  apps = {
    doctor = {
      type = "app";
      program = toString (
        pkgs.writeShellScript "doctor" ''
          export PATH="${lib.makeBinPath [ pkgs.python3 ]}:$PATH"
          exec ${pkgs.bash}/bin/bash ${../scripts/doctor.sh} "$@"
        ''
      );
      meta.description = "Run clean-clone documentation, planner, evaluation, and formatting checks";
    };
    control-center = {
      type = "app";
      program = "${controlCenterPackage}/bin/control-center";
      meta.description = "Open the unified Control Center widget";
    };
    tailscale-acl = {
      type = "app";
      program = toString (
        pkgs.writeShellScript "tailscale-acl" ''
          exec ${pkgs.coreutils}/bin/cat ${tailscaleAclPackage}
        ''
      );
      meta.description = "Print the generated Tailscale ACL (acl.hujson) JSON";
    };
    inventory-json = {
      type = "app";
      program = toString (
        pkgs.writeShellScript "inventory-json" ''
          exec ${pkgs.coreutils}/bin/cat ${self'.packages.inventory-data}/inventory.json
        ''
      );
      meta.description = "Print generated host inventory JSON";
    };
  };

  packages = {
    control-center = controlCenterPackage;
    inherit (pkgs)
      deadnix
      shellcheck
      statix
      ;

    inventory-data = import ../packages/inventory-data.nix {
      inherit
        lib
        pkgs
        hostRegistry
        ;
      allNixosConfigs = lib.intersectAttrs hostRegistry ciNixosConfigs;
    };

    drift-inventory-data = import ../packages/inventory-data.nix {
      inherit
        lib
        pkgs
        hostRegistry
        ;
      allNixosConfigs = lib.intersectAttrs hostRegistry ciNixosConfigs;
      includeClosureSizes = false;
    };

    tailscale-acl = tailscaleAclPackage;

    installer-iso =
      (nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inputs = flakeInputs;
        };
        modules = [ ../hosts/installer/default.nix ];
      }).config.system.build.isoImage;
  };

  formatter = treefmtEval.config.build.wrapper;

  devShells = {
    default = pkgs.mkShell {
      packages =
        (with pkgs; [
          nixd
          statix
          deadnix
          git
          jq
          sops
          ssh-to-age
          python3
          vulnix
          direnv
          nh
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
        # Only replace the shell for interactive sessions. `nix develop -c
        # <cmd>` runs this hook in a non-interactive bash, and execing zsh
        # there would replace `<cmd>` with an idle zsh and swallow its
        # output/exit status.
        case $- in
          *i*) exec ${pkgs.zsh}/bin/zsh ;;
        esac
      '';
    };

    security = pkgs.mkShell {
      packages = with pkgs; [
        nmap
        masscan
        rustscan
        traceroute
        whois
        dnsutils
        sqlmap
        gobuster
        ffuf
        feroxbuster
        nuclei
        amass
        nikto
        whatweb
        testssl
        hydra
        john
        hashcat
        netcat-gnu
        socat
        tcpdump
        wireshark-cli
        mitmproxy
        proxychains-ng
        seclists
        exploitdb
      ];
      shellHook = ''
        echo "Security tools ready"
        echo ""
        echo "Available tools:"
        echo "  Network:   nmap, masscan, rustscan, whois, dig, traceroute, netcat, socat"
        echo "  Web:       sqlmap, gobuster, ffuf, feroxbuster, nuclei, amass, nikto, whatweb, testssl"
        echo "  Password:  hydra, john, hashcat"
        echo "  Analysis:  tcpdump, wireshark-cli (tshark), mitmproxy"
        echo "  Data:      seclists, exploitdb"
      '';
    };
  };

  checks =
    deploy-rs.lib.${system}.deployChecks { nodes = ciDeployNodes; }
    // invariantChecks
    // {
      pre-commit = preCommitCheck;
      lib-generators = import ../tests/lib/generators.nix {
        inherit nixpkgs system;
      };
      lib-generators-structured = import ../tests/lib/generators-structured.nix {
        inherit nixpkgs system;
      };
      lib-acl = import ../tests/lib/acl.nix {
        inherit nixpkgs system;
      };
      lib-doctor = import ../tests/lib/doctor.nix {
        inherit nixpkgs system;
      };
      lib-mini-fleet-flake = import ../tests/lib/mini-fleet-flake.nix {
        inherit nixpkgs system;
      };
      lib-invariants = import ../tests/lib/invariants.nix {
        inherit nixpkgs system;
      };
      lib-host-registry = import ../tests/lib/host-registry.nix {
        inherit nixpkgs system;
      };
      lib-inventory-data = import ../tests/lib/inventory-data.nix {
        inherit nixpkgs system;
      };
      services-hardened = import ../tests/lib/services-hardened.nix {
        inherit nixpkgs system;
      };
      secrets-directory = import ../tests/lib/secrets-directory.nix {
        inherit nixpkgs system;
      };
      lib-scan-plaintext-secrets = import ../tests/lib/scan-plaintext-secrets.nix {
        inherit nixpkgs system;
      };
      python-template-hygiene = import ../tests/packages/python-template-hygiene.nix {
        inherit nixpkgs system;
      };
      theme-module = import ../tests/home/theme-module.nix {
        inherit nixpkgs system;
      };
      control-center-capabilities = import ../tests/packages/control-center-capabilities.nix {
        inherit nixpkgs system;
      };
    };
}
