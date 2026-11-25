# Retired: on-worker jobs now run on gcp-builder (#592). This host stays
# defined, and its VM stopped, until old job results have been pulled; then
# its registry entry, host and Terraform go in a follow-up.
{
  inputs,
  ...
}:
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ../../modules/nixos/profiles/gce-server.nix
    ../../modules/nixos/profiles/gce-on-demand.nix
    ../../modules/nixos/profiles/batch-jobs
  ];

  system.stateVersion = "26.11";

  networking = {
    hostName = "gcp-worker";
    firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];
  };

  # The VM is off most of the time, so a GC timer would rarely fire. Free space
  # while the store grows instead (5 and 15 GiB).
  nix.settings = {
    min-free = 5368709120;
    max-free = 16106127360;
  };

  profiles = {
    gceOnDemand = {
      enable = true;
      name = "worker";
      tag = "worker";
    };
    # Nothing builds here, so nix-daemon keeps its default weight.
    batchJobs = {
      enable = true;
      buildCPUWeight = null;
    };
  };
}
