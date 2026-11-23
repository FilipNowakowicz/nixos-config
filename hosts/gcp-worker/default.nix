{
  inputs,
  pkgs,
  ...
}:
let
  # Fixed so the idle check can find the job cgroups without asking systemd.
  jobsUid = 1001;

  # Runs one job inside its `systemd-run --user` unit (started by `on-worker run`
  # on main): logs to ~/jobs/<name>/log, records the exit status, and posts to
  # ntfy if a topic URL has been seeded.
  workerJob = pkgs.writeShellApplication {
    name = "worker-job";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      curl
    ];
    text = builtins.readFile ./worker-job.sh;
  };
in
{
  imports = [
    ../../packages/network-doctor
    inputs.disko.nixosModules.disko
    ./disko.nix
    ../../modules/nixos/profiles/gce-server.nix
    ../../modules/nixos/profiles/gce-on-demand.nix
  ];

  system.stateVersion = "26.11";

  # gce-server.nix grants `user` broad passwordless sudo and Nix trust for
  # deploy-rs, so SSH as `user` is root-equivalent. Jobs therefore run as
  # `jobs`, which has neither: code a job pulls in (PyPI packages, project
  # scripts) cannot reach root, the Tailscale state, or the Nix daemon's trust.
  # No `main` build ever substitutes from this host.

  networking = {
    hostName = "gcp-worker";
    firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];
  };

  # The VM is off most of the time, so a GC timer would rarely fire. Free space
  # while the store grows instead (5 and 15 GiB).
  nix.settings = {
    min-free = 5368709120;
    max-free = 16106127360;
  };

  profiles.gceOnDemand = {
    enable = true;
    name = "worker";
    tag = "worker";
    # A detached job holds no SSH connection. Each one is a `worker-job-*`
    # service under the jobs user's manager; any with a live process keeps the
    # box up. The unit's RuntimeMaxSec (set by on-worker) bounds a hung job.
    busyCheck = ''
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
  };

  # uv downloads its own Python builds and projects pull manylinux wheels; both
  # expect a normal dynamic loader.
  programs.nix-ld.enable = true;

  environment = {
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

  users.users = {
    # Key-only login. No sops on this host, so no console/recovery password is
    # provisioned; recover a wedged worker by reprovisioning. The personal keys
    # come from sops-base.
    jobs = {
      isNormalUser = true;
      uid = jobsUid;
      description = "Batch jobs started by on-worker";
      shell = pkgs.bash;
      # Detached `systemd-run --user` jobs need the user manager to outlive the
      # SSH session that started them.
      linger = true;
      openssh.authorizedKeys.keys = import ../../lib/pubkeys.nix;
    };
  };
}
