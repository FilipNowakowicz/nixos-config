# Show fleet notifications as desktop notifications (#630). Two subscriptions:
#
# - the self-hosted ntfy server on homeserver-gcp, over the tailnet with an
#   access token. Homeserver alerts and failures, main's own failures, the
#   builder's prebuild result, on-worker jobs and the phone backup check post
#   there. Its cache keeps a week, which covers suspend and reboots.
# - the public ntfy.sh fallback topic, for what can't go through that server:
#   failures of its own path on homeserver-gcp (nginx, ntfy, tailscaled,
#   Alertmanager, heartbeat), GitHub deploy failures and healthchecks.io.
#
# Each message carries a `source-*` tag (lib/ntfy.nix). It picks the app name
# and glyph, so a notification reads as coming from its source and the quiet
# shell groups it with that source. ntfy priority maps to urgency.
{
  config,
  hostRegistry,
  lib,
  pkgs,
  ...
}:
let
  ntfy = import ../../lib/ntfy.nix { inherit hostRegistry; };
  inherit (config.sops) secrets;
  stateDir = "${config.xdg.stateHome}/ntfy-notifications";

  # Runs once per message with ntfy's NTFY_* environment, plus the
  # subscription's NOTIFY_DEFAULT_SOURCE and NOTIFY_STATE_FILE.
  showMessage = pkgs.writeShellApplication {
    name = "fleet-show-message";
    runtimeInputs = with pkgs; [
      coreutils
      libnotify
    ];
    text = ''
      source=$NOTIFY_DEFAULT_SOURCE
      IFS=, read -ra tags <<<"''${NTFY_TAGS:-}"
      for tag in "''${tags[@]}"; do
        [[ $tag != source-* ]] || source=''${tag#source-}
      done

      case $source in
      ${lib.concatStrings (
        lib.mapAttrsToList (name: s: ''
          ${name}) app=${lib.escapeShellArg s.appName} glyph=${lib.escapeShellArg s.glyph} ;;
        '') ntfy.sources
      )}
      *) app=Notifications glyph=bell ;;
      esac

      case ''${NTFY_PRIORITY:-3} in
      1 | 2) urgency=low ;;
      4 | 5) urgency=critical ;;
      *) urgency=normal ;;
      esac

      notify-send --app-name="$app" --urgency="$urgency" \
        --hint=string:x-quiet-shell-glyph:"$glyph" \
        -- "''${NTFY_TITLE:-$app}" "''${NTFY_MESSAGE:-}" || true

      # Recorded after showing, so a crash repeats a message rather than losing it.
      mkdir -p "$(dirname "$NOTIFY_STATE_FILE")"
      printf '%s\n' "$NTFY_ID" >"$NOTIFY_STATE_FILE"
    '';
  };

  # One long-lived subscription. The topic URL is either given or read from a
  # secret file; the token, when there is one, reaches ntfy as NTFY_TOKEN.
  subscribe = pkgs.writeShellApplication {
    name = "fleet-subscribe";
    runtimeInputs = with pkgs; [
      coreutils
      ntfy-sh
    ];
    text = ''
      name=$1 url=$2 token_file=''${3:-}
      [[ $url != @* ]] || url=$(<"''${url#@}")
      if [[ -n $token_file ]]; then
        NTFY_TOKEN=$(<"$token_file")
        export NTFY_TOKEN
      fi
      export NOTIFY_STATE_FILE=${stateDir}/$name.last-id
      since=1h
      [[ ! -s $NOTIFY_STATE_FILE ]] || since=$(<"$NOTIFY_STATE_FILE")
      exec ntfy subscribe --since="$since" "$url" ${showMessage}/bin/fleet-show-message
    '';
  };

  mkSubscription =
    {
      description,
      name,
      url,
      tokenFile ? "",
      defaultSource,
    }:
    {
      Unit = {
        Description = description;
        After = [
          "graphical-session.target"
          "sops-nix.service"
        ];
        Wants = [ "sops-nix.service" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Environment = [ "NOTIFY_DEFAULT_SOURCE=${defaultSource}" ];
        ExecStart = "${subscribe}/bin/fleet-subscribe ${name} ${url} ${tokenFile}";
        Restart = "always";
        RestartSec = 30;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
in
{
  options.fleet.ntfy.sopsFile = lib.mkOption {
    type = lib.types.path;
    description = ''
      sops file holding the ntfy secrets: `token` (this user's access token on
      the self-hosted server), `builder_token` (the builder's publish token,
      which on-worker seeds) and `topic_url` (the public fallback topic URL).
    '';
  };

  config = {
    sops.secrets = {
      ntfy-token = {
        inherit (config.fleet.ntfy) sopsFile;
        key = "token";
      };
      ntfy-builder-token = {
        inherit (config.fleet.ntfy) sopsFile;
        key = "builder_token";
      };
      ntfy-topic-url = {
        inherit (config.fleet.ntfy) sopsFile;
        key = "topic_url";
      };
    };

    systemd.user.services = {
      ntfy-notifications = mkSubscription {
        description = "Desktop notifications from the self-hosted ntfy server";
        name = "fleet";
        url = ntfy.topicUrl;
        tokenFile = secrets.ntfy-token.path;
        defaultSource = "system";
      };
      ntfy-notifications-fallback = mkSubscription {
        description = "Desktop notifications from the public ntfy.sh fallback topic";
        name = "fallback";
        url = "@${secrets.ntfy-topic-url.path}";
        defaultSource = "homeserver";
      };
    };
  };
}
