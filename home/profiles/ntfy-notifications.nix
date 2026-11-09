# Show messages from the private ntfy topic as desktop notifications. Homeserver
# alerts, homeserver service failures and the builder's weekly prebuild result
# all publish there. The connection is outbound only, so no tailnet rule or open
# port is involved, and ntfy.sh's short message cache covers suspend and reboots.
{
  config,
  pkgs,
  ...
}:
let
  # Runs once per message with ntfy's NTFY_* environment.
  showMessage = pkgs.writeShellApplication {
    name = "ntfy-show-message";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      libnotify
    ];
    text = ''
      title=''${NTFY_TITLE:-Notification}
      body=''${NTFY_MESSAGE:-}
      urgency=normal
      [[ ''${NTFY_PRIORITY:-3} -lt 4 ]] || urgency=critical

      # Alertmanager posts its webhook payload as raw JSON.
      if status=$(jq -er 'select(type == "object" and has("alerts")) | .status' <<<"$body" 2>/dev/null); then
        title="Homeserver alert: $status"
        body=$(jq -r '.alerts[] | "\(.labels.alertname): \(.annotations.summary // .annotations.description // "")"' <<<"$body")
        [[ $status != firing ]] || urgency=critical
      fi

      notify-send --app-name=ntfy --urgency="$urgency" -- "$title" "$body" || true

      # Recorded after showing, so a crash repeats a message rather than losing it.
      mkdir -p "$XDG_STATE_HOME/ntfy-notifications"
      printf '%s\n' "$NTFY_ID" >"$XDG_STATE_HOME/ntfy-notifications/last-id"
    '';
  };

  subscribe = pkgs.writeShellApplication {
    name = "ntfy-subscribe";
    runtimeInputs = with pkgs; [
      coreutils
      ntfy-sh
    ];
    text = ''
      since=1h
      last_id="$XDG_STATE_HOME/ntfy-notifications/last-id"
      [[ ! -s $last_id ]] || since=$(<"$last_id")
      exec ntfy subscribe --since="$since" \
        "$(<${config.sops.secrets.ntfy-topic-url.path})" \
        ${showMessage}/bin/ntfy-show-message
    '';
  };
in
{
  sops.secrets.ntfy-topic-url = {
    sopsFile = ../users/user/secrets/ntfy.yaml;
    key = "topic_url";
  };

  systemd.user.services.ntfy-notifications = {
    Unit = {
      Description = "Desktop notifications from the private ntfy topic";
      After = [
        "graphical-session.target"
        "sops-nix.service"
      ];
      Wants = [ "sops-nix.service" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Environment = [ "XDG_STATE_HOME=${config.xdg.stateHome}" ];
      ExecStart = "${subscribe}/bin/ntfy-subscribe";
      Restart = "always";
      RestartSec = 30;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
