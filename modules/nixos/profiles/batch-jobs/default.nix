# The `on-worker` batch-job role: an unprivileged `jobs` account that runs
# long CPU-heavy jobs from any repository, started from `main` by `on-worker`
# (home/profiles/on-worker.nix). Enabled on gcp-builder, which also builds,
# so builds and jobs share one VM instead of competing for the project's CPU
# quota (#592).
#
# The host's `user` is root-equivalent (gce-server.nix: passwordless sudo and
# Nix trust for deploy-rs and remote builds). Jobs therefore run as `jobs`,
# which has neither: code a job pulls in (PyPI packages, project scripts)
# cannot reach root, the Tailscale state, or the Nix daemon's trust. The
# `workerJobsUserUnprivileged` invariant checks this.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.batchJobs;
  ntfy = import ../../../../lib/ntfy.nix { };

  # Fixed so the idle check can find the job cgroups without asking systemd.
  jobsUid = 1001;

  # Runs one job inside its `systemd-run --user` unit (started by `on-worker
  # run` on main): logs to ~/jobs/<name>/log, records the exit status, and
  # posts to the self-hosted ntfy server if a token has been seeded.
  workerJob = pkgs.writeShellApplication {
    name = "worker-job";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      curl
    ];
    runtimeEnv = {
      NOTIFY_URL = ntfy.topicUrl;
      NOTIFY_TAGS = ntfy.tags "on-worker";
    };
    text = builtins.readFile ./worker-job.sh;
  };
in
{
  # Jobs resolve PyPI and other indexes through AdGuard; `network-doctor worker`
  # (run as `jobs`) checks that path.
  imports = [ ../../../../packages/network-doctor ];

  options.profiles.batchJobs = {
    enable = lib.mkEnableOption "the unprivileged `jobs` account that runs on-worker batch jobs";

    buildCPUWeight = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 1 10000);
      default = 20;
      description = ''
        systemd CPUWeight for nix-daemon (builds), against the default 100 of
        the jobs user's slice. When both are busy, builds get about a sixth
        of the CPUs; when either is idle, the other has the whole VM. Null
        leaves nix-daemon at the default weight.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # A detached job holds no SSH connection. Each one is a `worker-job-*`
    # service under the jobs user's manager; any with a live process keeps the
    # box up. The unit's RuntimeMaxSec (set by on-worker) bounds a hung job.
    profiles.gceOnDemand.busyCheck = ''
      jobs_cgroup=/sys/fs/cgroup/user.slice/user-${toString jobsUid}.slice/user@${toString jobsUid}.service
      if [ -d "$jobs_cgroup" ]; then
        while IFS= read -r procs; do
          if ${pkgs.gnugrep}/bin/grep -q . "$procs" 2>/dev/null; then
            mark_active
            exit 0
          fi
        done < <(${pkgs.findutils}/bin/find "$jobs_cgroup" -path '*/worker-job-*.service/cgroup.procs')
      fi
    '';

    # Builds run inside nix-daemon's cgroup. cgroup v2 shares CPU between
    # sibling slices first (system.slice vs user.slice), so process nice
    # values alone would not stop a build from taking half the VM from a job.
    # Forced over base.nix's fleet-wide 50, which is tuned for desktops.
    systemd.services.nix-daemon.serviceConfig = lib.mkIf (cfg.buildCPUWeight != null) {
      CPUWeight = lib.mkForce cfg.buildCPUWeight;
      IOWeight = lib.mkForce cfg.buildCPUWeight;
    };

    # uv downloads its own Python builds and projects pull manylinux wheels;
    # both expect a normal dynamic loader.
    programs.nix-ld.enable = true;

    environment = {
      # uv's standalone Python builds read OpenSSL's default CA file, which
      # NixOS doesn't create; point it at the system bundle so TLS works.
      etc."ssl/cert.pem".source = config.environment.etc."ssl/certs/ca-certificates.crt".source;

      systemPackages = [
        workerJob
      ]
      ++ (with pkgs; [
        git
        htop
        jq
        rsync # on-worker syncs checkouts with it
        tmux
        uv
      ]);
      # Use uv-managed interpreters only, as on main (home/profiles/python-development.nix).
      variables.UV_PYTHON_PREFERENCE = "only-managed";
    };

    # Key-only login with the personal keys. No console/recovery password.
    users.users.jobs = {
      isNormalUser = true;
      uid = jobsUid;
      description = "Batch jobs started by on-worker";
      shell = pkgs.bash;
      # Detached `systemd-run --user` jobs need the user manager to outlive
      # the SSH session that started them.
      linger = true;
      openssh.authorizedKeys.keys = import ../../../../lib/pubkeys.nix;
    };
  };
}
