# Read-only calendars for the quiet shell's agenda. vdirsyncer keeps a local copy,
# and packages/quiet-shell/shell/scripts/agenda.py reads it through khal.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # An iCal link is a password for reading that calendar. Each name is a key in
  # the sops file, so adding a calendar is that key and one word here.
  privateFeeds = [
    "imperial"
    "primary"
  ];

  publicFeeds.holidays = "https://calendar.google.com/calendar/ical/pl.polish%23holiday%40group.v.calendar.google.com/public/basic.ics";

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
  sops.secrets = lib.genAttrs (map (name: "calendar-${name}") privateFeeds) (secret: {
    sopsFile = ../users/user/secrets/calendar-feeds.yaml;
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
        # The anonymous boot has no age key, so nothing decrypts there. Stopping on
        # that keeps it from contacting any feed, including the public ones.
        ConditionPathExists = secretPath (lib.head privateFeeds);
      };
      Service.ExecStartPre = [
        "${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArgs calendarDirs}"
        # Home Manager's service leaves this out, and sync refuses to run without it.
        "${lib.getExe config.programs.vdirsyncer.package} discover"
      ];
    };
  };
}
