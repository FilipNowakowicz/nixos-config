{
  lib,
  pkgs,
  system,
  nixpkgs,
  pre-commit-hooks,
  treefmt-nix,
  hostRegistry,
  vmRegistry,
  ciNixosConfigs,
  aclGen,
  deploy-rs,
  nixos-anywhere,
  flakeInputs,
  ciDeployNodes,
  invariantChecks,
}:
let
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
        exec ${pkgs.bash}/bin/bash ${../scripts/vm.sh} "$@"
      ''
    );
    meta.description = "Manage QEMU/KVM virtual machines";
  };

  waybarWidgetPreviewPackage =
    let
      python = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
      src = pkgs.writeText "waybar_widget_preview.py" (
        builtins.readFile ../home/files/scripts/waybar_widget_preview.py
      );
      runtimePath = lib.makeBinPath (
        with pkgs;
        [
          bluez
          blueman
          networkmanager
          networkmanagerapplet
          pavucontrol
          wireplumber
        ]
      );
    in
    pkgs.stdenv.mkDerivation {
      name = "waybar-widget-preview";
      dontUnpack = true;

      nativeBuildInputs = with pkgs; [
        gobject-introspection
        wrapGAppsHook4
      ];

      buildInputs = with pkgs; [
        glib
        pango
        gdk-pixbuf
        graphene
        harfbuzz
        gtk4
        gtk4-layer-shell
      ];

      installPhase = ''
        mkdir -p $out/bin $out/libexec
        cp ${src} $out/libexec/waybar_widget_preview.py
        cat > $out/bin/waybar-widget-preview <<EOF
        #!${pkgs.bash}/bin/sh
        exec ${python}/bin/python3 $out/libexec/waybar_widget_preview.py "\$@"
        EOF
        chmod +x $out/bin/waybar-widget-preview
      '';

      preFixup = ''
        gappsWrapperArgs+=(
          --set GDK_BACKEND wayland
          --set GTK4_LAYER_SHELL_LIB "${pkgs.gtk4-layer-shell}/lib/libgtk4-layer-shell.so.0"
          --prefix PATH : "${runtimePath}"
        )
      '';
    };

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
    vm = vmApp;
    waybar-widget-preview = {
      type = "app";
      program = "${waybarWidgetPreviewPackage}/bin/waybar-widget-preview";
      meta.description = "Open the static Waybar widget preview popup";
    };
  };

  packages = {
    waybar-widget-preview = waybarWidgetPreviewPackage;

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
      lib-generators = import ../tests/lib/generators.nix {
        inherit nixpkgs system;
      };
      lib-generators-golden = import ../tests/lib/generators.golden.nix {
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
    };
}
