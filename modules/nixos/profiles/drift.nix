# Host-declared facts for the drift check (scripts/check-host-drift.sh).
# Read by lib/inventory-data.nix for the fleet inventory and by any host that
# publishes its own /etc/host-drift-inventory.json, so both copies agree.
{ lib, ... }:
{
  options.profiles.drift = {
    trackedServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "nginx"
        "grafana"
      ];
      description = ''
        Inventory `services` keys whose health this host is expected to report;
        exported as the inventory's `trackedServices`.
      '';
    };

    expectedExtraTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = ''
        Stable listeners that bind a non-loopback address but are deliberately
        not opened on tailscale0, so they never appear in the drift `tcpPorts`.
        Without them the strict drift check flags these ports as unexpected on
        every run. List only ports reachable from the host itself or a
        firewalled interface. tailscaled's dynamic WireGuard ports do not
        belong here: they change every restart, and check-host-drift.sh drops
        them by tailnet address.
      '';
    };
  };
}
