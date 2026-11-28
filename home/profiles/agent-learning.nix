# The weekly learning loop (#650): once a week a miner model reads the past
# week's Claude Code and Codex sessions in ~/nix and files learning candidates;
# a separate reviewer model (fresh context, its own worktree of origin/main)
# verifies them against the source and implements or rejects them in one PR.
# The PR auto-merges through merge-gate when it only touches the agent surface.
# See .agents/learning/README.md.
#
# The miner runs on Codex and the reviewer on Claude, so the two subscriptions
# share the load and the model that files a lesson never judges it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.agentLearning;
  ntfy = import ../../lib/ntfy.nix { };
  home = config.home.homeDirectory;

  # The scripts and prompts are copied into the store, so a run uses what was
  # deployed, not whatever branch ~/nix has checked out.
  learning = lib.fileset.toSource {
    root = ../../.agents/learning;
    fileset = lib.fileset.unions [
      ../../.agents/learning/scripts
      ../../.agents/learning/prompts
    ];
  };

  weekly = pkgs.writeShellApplication {
    name = "agent-learning-weekly";
    # claude and codex come from the user profile on PATH; nix for the
    # reviewer's validation from the system.
    runtimeInputs = with pkgs; [
      coreutils
      curl
      findutils
      gawk
      gh
      git
      gnugrep
      gnused
      jq
      python3
    ];
    text = ''
      exec bash ${learning}/scripts/weekly.sh "$@"
    '';
  };
in
{
  options.fleet.agentLearning = {
    miner = lib.mkOption {
      type = lib.types.enum [
        "codex"
        "claude"
      ];
      default = "codex";
      description = "Agent CLI that mines the session digest; the other one reviews (Claude reviews either way).";
    };
    autoMerge = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable auto-merge on review PRs that only touch the agent surface.";
    };
    schedule = lib.mkOption {
      type = lib.types.str;
      # Friday, the day of the weekly flake.lock update (18:00 UTC).
      default = "Fri *-*-* 10:00";
      description = "systemd OnCalendar for the weekly run.";
    };
    claudeTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File holding a long-lived Claude Code token (`claude setup-token`) for the
        unattended reviewer. Interactive sign-ins expire; without this the run
        fails once they do.
      '';
    };
  };

  config = {
    home.packages = [ weekly ];

    systemd.user = {
      services.agent-learning-weekly = {
        Unit = {
          Description = "Weekly agent learning review (mine sessions, review, open a PR)";
          After = [ "sops-nix.service" ];
          Wants = [ "sops-nix.service" ];
        };
        Service = {
          Type = "oneshot";
          ExecStart = lib.getExe weekly;
          Environment = [
            "AGENT_LEARNING_REPO=${home}/nix"
            "AGENT_LEARNING_WORKTREES=${home}/.local/share/worktrees/nix"
            "LEARNING_ARCHIVE=${home}/nix/.agents/learning/candidates/archive"
            "AGENT_LEARNING_MINER=${cfg.miner}"
            "AGENT_LEARNING_AUTO_MERGE=${if cfg.autoMerge then "1" else "0"}"
            "AGENT_LEARNING_NTFY_URL=${ntfy.topicUrl}"
            "AGENT_LEARNING_NTFY_TOKEN_FILE=${config.sops.secrets.ntfy-token.path}"
            "AGENT_LEARNING_NTFY_TAGS=${ntfy.tags "agents"}"
          ]
          ++ lib.optional (
            cfg.claudeTokenFile != null
          ) "AGENT_LEARNING_CLAUDE_TOKEN_FILE=${cfg.claudeTokenFile}";
          TimeoutStartSec = "4h";
          Nice = 10;
        };
      };
      timers.agent-learning-weekly = {
        Unit.Description = "Run the agent learning review weekly";
        Timer = {
          OnCalendar = cfg.schedule;
          RandomizedDelaySec = "30m";
          Persistent = true;
        };
        Install.WantedBy = [ "timers.target" ];
      };
    };
  };
}
