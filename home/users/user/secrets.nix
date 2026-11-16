{ config, lib, ... }:
let
  cfg = config.userSecrets;
  homeDir = config.home.homeDirectory;
  configDir = config.xdg.configHome;
in
{
  options.userSecrets.enable = lib.mkEnableOption "Home Manager-managed backup and restore for selected user auth files";

  config = lib.mkIf cfg.enable {
    home = {
      file = {
        ".codex/.keep".text = "";
        ".claude/.keep".text = "";
        ".gemini/.keep".text = "";
      };

      activation = {
        removeLegacyCodexSopsAuth = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          auth_file="${homeDir}/.codex/auth.json"
          legacy_target="${configDir}/sops-nix/secrets/codex-auth"

          if [ -L "$auth_file" ] && [ "$(readlink "$auth_file")" = "$legacy_target" ]; then
            $DRY_RUN_CMD rm "$auth_file"
          fi
        '';

        removeLegacyClaudeSopsCredentials = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          creds_file="${homeDir}/.claude/.credentials.json"
          legacy_target="${configDir}/sops-nix/secrets/claude-credentials"

          if [ -L "$creds_file" ] && [ "$(readlink "$creds_file")" = "$legacy_target" ]; then
            $DRY_RUN_CMD rm "$creds_file"
          fi
        '';
      };
    };

    sops = {
      age.keyFile = "${configDir}/sops/age/keys.txt";

      secrets = {
        gh-hosts = {
          format = "yaml";
          sopsFile = ./secrets/gh-hosts.yaml;
          key = "";
          path = "${configDir}/gh/hosts.yml";
        };

        gcloud-adc = {
          format = "json";
          sopsFile = ./secrets/gcloud-application_default_credentials.json;
          key = "";
          path = "${configDir}/gcloud/application_default_credentials.json";
        };

        git_user_name.sopsFile = ./secrets/user-identity.yaml;
        git_user_email.sopsFile = ./secrets/user-identity.yaml;
      };

      # Git identity rendered at activation; common.nix includes this file so
      # signing/commits pick up name + email without the values being committed.
      templates."git-identity.gitconfig".content = ''
        [user]
        name = ${config.sops.placeholder.git_user_name}
        email = ${config.sops.placeholder.git_user_email}
      '';
    };

    programs.git.includes = [
      { path = config.sops.templates."git-identity.gitconfig".path; }
    ];
  };
}
