# Drift facts derived from a host's evaluated NixOS config, shared by
# lib/inventory-data.nix and hosts that publish /etc/host-drift-inventory.json.
{ lib }:
{
  # The systemd units check-host-drift.sh expects to be active.
  systemdUnits =
    c:
    lib.filter (unit: unit != "") [
      (lib.optionalString c.services.openssh.enable "sshd.service")
      (lib.optionalString c.services.tailscale.enable "tailscaled.service")
      (lib.optionalString (c.services.nginx.enable or false) "nginx.service")
      (lib.optionalString (c.services.adguardhome.enable or false) "adguardhome.service")
      (lib.optionalString (c.services.grafana.enable or false) "grafana.service")
      (lib.optionalString (c.services.loki.enable or false) "loki.service")
      (lib.optionalString (c.services.prometheus.enable or false) "prometheus.service")
      (lib.optionalString (c.services.prometheus.alertmanager.enable or false) "alertmanager.service")
    ];
}
