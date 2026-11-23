{ lib }:
let
  runner = cfg: cfg.systemd.services.github-runner-homeserver-deploy or { };
in
{
  selfSwitch = {
    name = "homeserver deploy runner survives self-switch";
    check = cfg: {
      passed = !((runner cfg).restartIfChanged or true);
      message = "github-runner-homeserver-deploy.restartIfChanged must be false so activation can finish inside the runner";
    };
  };

  runbook = {
    name = "runner recovery runbook references the configured state directory and unit";
    check =
      cfg:
      let
        dirs = lib.toList ((runner cfg).serviceConfig.StateDirectory or [ ]);
        runbook = lib.fileContents ./CLAUDE.md;
      in
      {
        passed =
          dirs != [ ]
          && lib.head dirs != ""
          && lib.hasInfix "sudo find /var/lib/${lib.head dirs} -mindepth 1 -delete" runbook
          && lib.hasInfix "systemctl stop github-runner-homeserver-deploy.service" runbook;
        message = "check the runner unit and state-cleanup command in hosts/homeserver-gcp/CLAUDE.md";
      };
  };
}
