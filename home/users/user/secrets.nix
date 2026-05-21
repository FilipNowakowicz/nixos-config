{ config, lib, ... }:
let
  cfg = config.userSecrets;
  homeDir = config.home.homeDirectory;
  configDir = config.xdg.configHome;
in
{
  options.userSecrets.enable = lib.mkEnableOption "Home Manager-managed backup and restore for selected user auth files";

  config = lib.mkIf cfg.enable {
    home.file = {
      ".codex/.keep".text = "";
      ".claude/.keep".text = "";
      ".gemini/.keep".text = "";
    };

    xdg.configFile = {
      "gh/.keep".text = "";
      "gcloud/.keep".text = "";
    };

    sops = {
      age.keyFile = "${configDir}/sops/age/keys.txt";

      secrets = {
        codex-auth = {
          format = "json";
          sopsFile = ./secrets/codex-auth.json;
          key = "";
          path = "${homeDir}/.codex/auth.json";
        };

        claude-credentials = {
          format = "json";
          sopsFile = ./secrets/claude-credentials.json;
          key = "";
          path = "${homeDir}/.claude/.credentials.json";
        };

        gemini-oauth-creds = {
          format = "json";
          sopsFile = ./secrets/gemini-oauth_creds.json;
          key = "";
          path = "${homeDir}/.gemini/oauth_creds.json";
        };

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
