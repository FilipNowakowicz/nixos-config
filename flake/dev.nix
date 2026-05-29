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
}:
let
  controlCenterPackage = pkgs.callPackage ../packages/control-center { };

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
          sops
          ssh-to-age
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
        exec ${pkgs.zsh}/bin/zsh
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
      lib-invariants = import ../tests/lib/invariants.nix {
        inherit nixpkgs system;
      };
      secrets-directory = import ../tests/lib/secrets-directory.nix {
        inherit nixpkgs system;
      };
      lib-scan-plaintext-secrets = import ../tests/lib/scan-plaintext-secrets.nix {
        inherit nixpkgs system;
      };
    };
}
