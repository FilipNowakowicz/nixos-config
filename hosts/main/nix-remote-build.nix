# Distributed-build support for offloading heavy builds to the on-demand
# `gcp-builder` host. See hosts/gcp-builder and scripts/validate.sh.
#
# Deliberately NOT setting nix.buildMachines system-wide: the builder is usually
# powered off, and a global build machine would make every ordinary `rebuild`
# pay an SSH-connect timeout before falling back to local. Instead validate.sh
# starts the VM and passes `--builders` for that one invocation. This module
# only provides the pieces that must live in the system: the decrypted SSH key,
# root's host-key policy for the builder, and substitute fetching on the remote.
{
  hostRegistry,
  ...
}:
let
  builderFqdn = hostRegistry.gcp-builder.tailnetFQDN;
in
{
  # Private half of the dedicated build key (public half is authorized on the
  # builder). root's nix-daemon reads this to drive distributed builds.
  sops.secrets.gcp_builder_build_key = {
    sopsFile = ./secrets/gcp_builder_build_key.enc;
    format = "binary";
    mode = "0400";
  };

  # The builder's SSH host key is created at provisioning, so it cannot be pinned
  # declaratively up front. Connections ride authenticated Tailscale WireGuard, so
  # accept-new is acceptable here. After reprovisioning the builder its host key
  # changes; clear the stale entry (or reboot main, whose /root is ephemeral).
  programs.ssh.extraConfig = ''
    Host ${builderFqdn}
      StrictHostKeyChecking accept-new
  '';

  # Let the builder pull dependencies straight from the binary caches instead of
  # main copying every input over SSH.
  nix.settings.builders-use-substitutes = true;
}
