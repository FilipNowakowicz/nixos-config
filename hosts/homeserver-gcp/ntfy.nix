# Self-hosted ntfy (#630): the fleet's notification server, reachable only
# over the tailnet.
#
# - ntfy listens on loopback. nginx serves it with the Tailscale certificate on
#   its own port, which the firewall opens on tailscale0 only and the tailnet
#   ACL admits from the owner's devices and gcp-builder (lib/hosts.nix).
# - Anonymous access is denied. Users, their topic grants and access tokens are
#   declarative: they are rebuilt from sops secrets on every start, so the user
#   database holds nothing that has to be backed up. The phone logs in with a
#   password; every other client uses a token.
# - The message cache covers a week offline. It is the only state, and losing
#   it loses only already-delivered notifications, so it is not backed up.
# - Alertmanager alerts are formatted server-side by the `fleet-alert` template.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.homeserverGcpNtfy;
  ntfy = import ../../lib/ntfy.nix { };
  certDir = "/var/lib/nginx-certs";
  settingsFormat = pkgs.formats.yaml { };

  # Alertmanager webhook payload -> readable notification, with the priority
  # taken from the alerts' severity. Templates read the raw JSON body.
  templates = pkgs.writeTextDir "fleet-alert.yml" (
    builtins.toJSON {
      title = lib.concatStrings [
        "[{{ .status | upper }}] {{ .commonLabels.alertname | default (index .alerts 0).labels.alertname }}"
        ''{{ with (index .alerts 0).labels }} on {{ .host | default .instance | default "the fleet" }}{{ end }}''
        "{{ if gt (len .alerts) 1 }} (+{{ sub (len .alerts) 1 }} more){{ end }}"
      ];
      message = lib.concatStrings [
        ''{{ range $i, $a := .alerts }}{{ if $i }}{{ "\n" }}{{ end }}''
        "{{ $a.annotations.summary | default $a.annotations.description | default $a.labels.alertname }}"
        "{{ end }}"
      ];
      priority = lib.concatStrings [
        ''{{ if eq .status "resolved" }}2''
        ''{{ else if eq (.commonLabels.severity | default "") "critical" }}5''
        ''{{ else if eq (.commonLabels.severity | default "") "warning" }}3''
        "{{ else }}4{{ end }}"
      ];
    }
  );

  # ntfy needs a password hash for every user. Token-only users get the hash
  # of a random password nobody knows, so they can't log in with one.
  tokenUsers = lib.attrNames cfg.tokenFiles;
  start = pkgs.writeShellApplication {
    name = "ntfy-serve";
    runtimeInputs = with pkgs; [
      coreutils
      mkpasswd
    ];
    text = ''
      creds=$CREDENTIALS_DIRECTORY
      hash() { mkpasswd --method=bcrypt --rounds=10 --stdin; }
      unusable=$(head -c 32 /dev/urandom | base64 | hash)

      users="phone:$(hash <"$creds/phone-password"):user"
      access="phone:${ntfy.topic}:ro"
      tokens=""
      for user in ${lib.escapeShellArgs tokenUsers}; do
        users+=",$user:$unusable:user"
        tokens+="''${tokens:+,}$user:$(<"$creds/token-$user"):$user"
      done
      ${lib.concatMapStrings (user: ''
        access+=${lib.escapeShellArg ",${user}:${ntfy.topic}:${cfg.tokenAccess.${user}}"}
      '') tokenUsers}
      export NTFY_AUTH_USERS=$users NTFY_AUTH_ACCESS=$access NTFY_AUTH_TOKENS=$tokens
      exec ${lib.getExe config.services.ntfy-sh.package} serve \
        --config ${settingsFormat.generate "server.yml" config.services.ntfy-sh.settings}
    '';
  };
in
{
  options.profiles.homeserverGcpNtfy = {
    enable = lib.mkEnableOption "the tailnet-only ntfy server";

    fqdn = lib.mkOption {
      type = lib.types.str;
      description = "Tailnet name nginx serves ntfy under, with the host's Tailscale certificate.";
    };

    phonePasswordFile = lib.mkOption {
      type = lib.types.path;
      description = "Runtime file with the password of the read-only `phone` user.";
    };

    tokenFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      description = ''
        Runtime files with one ntfy access token (`tk_` plus 29 characters)
        per token-only user, keyed by user name.
      '';
    };

    tokenAccess = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.enum [
          "ro"
          "wo"
          "rw"
        ]
      );
      description = "Each token user's permission on the fleet topic.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.attrNames cfg.tokenAccess == tokenUsers;
        message = "profiles.homeserverGcpNtfy: tokenAccess and tokenFiles must name the same users";
      }
    ];

    services.ntfy-sh = {
      enable = true;
      settings = {
        base-url = "https://${cfg.fqdn}:${toString ntfy.port}";
        listen-http = "127.0.0.1:${toString ntfy.internalPort}";
        behind-proxy = true;
        auth-default-access = "deny-all";
        # The web app needs a login, like everything else.
        enable-login = true;
        require-login = true;
        # A week covers a laptop or phone that stays offline for a few days.
        cache-duration = "168h";
        template-dir = "${templates}";
        log-format = "json";
      };
    };

    systemd.services.ntfy-sh.serviceConfig = {
      # The module's ExecStart is replaced so the declarative users, grants
      # and tokens can come from runtime secrets.
      ExecStart = lib.mkForce (lib.getExe start);
      LoadCredential = [
        "phone-password:${toString cfg.phonePasswordFile}"
      ]
      ++ lib.mapAttrsToList (user: file: "token-${user}:${toString file}") cfg.tokenFiles;
      Restart = "on-failure";
      RestartSec = 5;
    };

    services.nginx.virtualHosts.ntfy = {
      onlySSL = true;
      serverName = cfg.fqdn;
      listen = [
        {
          addr = "0.0.0.0";
          inherit (ntfy) port;
          ssl = true;
        }
      ];
      sslCertificate = "${certDir}/homeserver-gcp.crt";
      sslCertificateKey = "${certDir}/homeserver-gcp.key";
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString ntfy.internalPort}";
        proxyWebsockets = true;
        # Subscriptions are long-lived streams: pass them through unbuffered
        # and outlast ntfy's 45 s keepalive.
        extraConfig = ''
          proxy_buffering off;
          proxy_request_buffering off;
          proxy_connect_timeout 3m;
          proxy_send_timeout 3m;
          proxy_read_timeout 3m;
          client_max_body_size 64k;
        '';
      };
    };

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ ntfy.port ];
  };
}
