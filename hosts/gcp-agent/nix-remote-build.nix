# Distributed-build support for offloading heavy builds to the on-demand
# `gcp-builder` host, mirroring hosts/main/nix-remote-build.nix.
#
# Deliberately NOT setting nix.buildMachines system-wide: the builder is usually
# powered off, and a global build machine would make every ordinary build pay an
# SSH-connect timeout before falling back to local. Instead `ensure_builder` in
# scripts/validate.sh starts the VM and passes `--builders` for that one
# invocation. This module only provides the pieces that must live in the
# system: the decrypted SSH key, root's host-key policy for the builder, and
# substitute fetching on the remote.
#
# Uses a dedicated `nix-remote-build-gcp-agent-to-gcp-builder` key, separate
# from main's `gcp_builder_build_key`, so this disposable, narrow-sudo box's
# credential to gcp-builder (root-equivalent there) is independently revocable
# without touching main's. See docs/remote-builder.md and
# hosts/gcp-builder/CLAUDE.md for rotation.
{
  hostRegistry,
  ...
}:
let
  builderFqdn = hostRegistry.gcp-builder.tailnetFQDN;
in
{
  # Owned by `user` (not the main-style root-only 0400): this host's `user` has
  # no personal SSH key (no `&user` age key, see hosts/gcp-agent/CLAUDE.md), so
  # scripts/validate.sh's unprivileged readiness probe needs to authenticate
  # with this same key. Root's nix-daemon can still read a user-owned file for
  # the actual --builders SSH connection.
  sops.secrets.gcp_builder_build_key = {
    sopsFile = ./secrets/gcp_builder_build_key.enc;
    format = "binary";
    owner = "user";
    mode = "0400";
  };

  # The builder's SSH host key is created at provisioning, so it cannot be
  # pinned declaratively up front. Connections ride authenticated Tailscale
  # WireGuard, so accept-new is acceptable here. After reprovisioning the
  # builder its host key changes; clear the stale entry on this host to recover
  # (this host is disposable, so reprovisioning also clears it).
  programs.ssh.extraConfig = ''
    Host ${builderFqdn}
      StrictHostKeyChecking accept-new
  '';

  # Let the builder pull dependencies straight from the binary caches instead of
  # this host copying every input over SSH.
  nix.settings.builders-use-substitutes = true;
}
