# Tailnet presence of the other registry hosts, as seen from this host.
#
# GcpBuilderLeftRunning (lib/observability-alerts.nix) alerts when gcp-builder
# stays online for hours, i.e. its idle shutdown is broken. This host already
# peers with the builder (the builder resolves DNS through AdGuard here), so
# tailscaled's own `Online` flag from the control plane answers "is it up?"
# without GCP credentials: no service account, no IAM grant, nothing new to
# rotate. A stopped VM drops off the tailnet within a couple of minutes.
#
# A failing `tailscale status` fails the unit (SystemdUnitFailed) and leaves
# the previous sample in place, so a broken writer is not silent.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.lib.profiles.observability) mkPromScript;
  hostRegistry = import ../../lib/hosts.nix;

  peers = lib.filterAttrs (
    name: host: name != config.networking.hostName && host.status == "active" && host ? tailnetFQDN
  ) hostRegistry;

  varName = name: "online_${lib.replaceStrings [ "-" ] [ "_" ] name}";
in
{
  systemd = {
    services.tailnet-presence = {
      description = "Export tailnet presence of registry hosts for Prometheus";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "tailnet-presence" ''
          set -euo pipefail
          status=$(${config.services.tailscale.package}/bin/tailscale status --json)
          ${lib.concatMapStrings (name: ''
            ${varName name}=$(${pkgs.jq}/bin/jq -r --arg dns ${lib.escapeShellArg "${peers.${name}.tailnetFQDN}."} \
              'if [.Peer // {} | .[] | select(.DNSName == $dns) | .Online] | any then 1 else 0 end' <<<"$status")
            export ${varName name}
          '') (builtins.attrNames peers)}
          exec ${
            mkPromScript {
              name = "tailnet_presence.prom";
              lines = [
                "# HELP tailscale_peer_online Whether the registry host is online in the tailnet (tailscale status)"
                "# TYPE tailscale_peer_online gauge"
              ]
              ++ map (name: ''tailscale_peer_online{peer="${name}"} ''$${varName name}'') (
                builtins.attrNames peers
              );
            }
          }
        '';
      };
    };

    timers.tailnet-presence = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "1min";
      };
    };
  };
}
