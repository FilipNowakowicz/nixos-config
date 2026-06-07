_:
# ── Build resource seatbelt ──────────────────────────────────────────────────
# homeserver-gcp is a 4 GB e2-medium that also runs the full LGTM stack +
# Vaultwarden + AdGuard + nginx. A heavy Nix build here (e.g. the deploy
# closure) can exhaust RAM, swap-thrash the box catatonic, and take the live
# services down — tailnet goes unresponsive while only the runner's outbound
# socket survives (incident 2026-06-07, #112).
#
# The primary fix lives in .github/workflows/deploy-homeserver.yml: the heavy
# validation/build gates run on GitHub-hosted runners, so only the lightweight
# incremental deploy build ever touches this host. The limits below are the
# backstop that guarantees even an unexpectedly large on-host build can never
# again starve the live services into death.
{
  # Real disk-backed swap. The base profile only enables zramSwap (compressed
  # RAM), which gives no headroom under a genuine multi-GB blowout. A swapfile
  # lets the kernel page out idle pages instead of OOM-thrashing tailscaled /
  # nginx / the LGTM stack.
  swapDevices = [
    {
      device = "/var/swapfile";
      size = 4096; # MiB
    }
  ];

  # Cap build parallelism: on 2 vCPU / 4 GB a deploy build must not fan out into
  # several memory-heavy compiler/linker jobs at once.
  nix.settings.max-jobs = 1;

  # Soft memory ceiling on the build daemon. Above this the cgroup is throttled
  # and reclaimed (pushed to swap), NOT killed — so a large build runs slowly
  # but the host stays alive. Deliberately MemoryHigh (soft) rather than
  # MemoryMax (hard OOM-kill), to avoid killing nix-daemon mid-deploy.
  systemd.services.nix-daemon.serviceConfig.MemoryHigh = "2G";
}
