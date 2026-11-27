# Read-only calendars for the quiet shell's agenda. vdirsyncer keeps a local copy,
# and packages/quiet-shell/shell/scripts/agenda.py reads it through khal.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.calendar;
  inherit (cfg) privateFeeds publicFeeds;

  secretPath = name: config.sops.secrets."calendar-${name}".path;

  mkCalendar = fields: {
    remote.type = "http";
    local = {
      type = "filesystem";
      fileExt = ".ics";
    };
    khal = {
      enable = true;
      readOnly = true;
    };
    vdirsyncer = {
      enable = true;
      collections = null;
      conflictResolution = "remote wins";
    }
    // fields;
  };

  calendarDirs = lib.mapAttrsToList (
    _: account: account.local.path
  ) config.accounts.calendar.accounts;
in
{
  options.fleet.calendar = {
    sopsFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        sops file holding the private iCal links, one key per private feed name.
      '';
    };

    # An iCal link is a password for reading that calendar, so private feeds
    # are named here and their links live in `sopsFile` under the same key.
    privateFeeds = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      description = "Private calendar names; each is a key in `sopsFile`.";
    };

    publicFeeds = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Public calendars by name, as plain iCal URLs.";
    };
  };

  config = {
    sops.secrets = lib.genAttrs (map (name: "calendar-${name}") privateFeeds) (secret: {
      inherit (cfg) sopsFile;
      key = lib.removePrefix "calendar-" secret;
    });

    accounts.calendar = {
      basePath = ".local/share/calendars";
      accounts =
        lib.genAttrs privateFeeds (
          name:
          mkCalendar {
            urlCommand = [
              "${pkgs.coreutils}/bin/cat"
              (secretPath name)
            ];
          }
        )
        // lib.mapAttrs (
          _: url: lib.recursiveUpdate (mkCalendar { }) { remote = { inherit url; }; }
        ) publicFeeds;
    };

    programs = {
      vdirsyncer.enable = true;
      khal = {
        enable = true;
        # agenda.py depends on these.
        locale = {
          dateformat = "%Y-%m-%d";
          longdateformat = "%Y-%m-%d";
          timeformat = "%H:%M";
          datetimeformat = "%Y-%m-%d %H:%M";
          longdatetimeformat = "%Y-%m-%d %H:%M";
          firstweekday = 0;
        };
      };
    };

    services.vdirsyncer = {
      enable = true;
      frequency = "*:0/30";
    };

    systemd.user = {
      timers.vdirsyncer.Timer.Persistent = true;
      services.vdirsyncer = {
        Unit = {
          After = [ "sops-nix.service" ];
          # Wait for the private feed credential before syncing any feeds.
          ConditionPathExists = secretPath (lib.head privateFeeds);
        };
        Service.ExecStartPre = [
          "${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArgs calendarDirs}"
          # Home Manager's service leaves this out, and sync refuses to run without it.
          "${lib.getExe config.programs.vdirsyncer.package} discover"
        ];
      };
    };
  };
}
