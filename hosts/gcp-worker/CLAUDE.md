# gcp-worker Host

On-demand GCP VM for long CPU-heavy jobs from any repository (model
calibrations, simulations, test matrices), so they do not load `main`.
Normally **powered off**. `on-worker` on `main` starts it, the VM stays up while
a job runs, and it powers itself off 20 minutes after the last job or SSH
session ends. Disposable: no sops, no backup, no service state beyond job
workspaces.

Status: **active**.

## What it is / isn't

- **Is:** a headless `n2-custom-14-14336` (14 vCPU, 14 GB) running batch jobs
  as the unprivileged `jobs` user, with uv and nix-ld for Python projects.
- **Isn't:** a Nix builder or a service host. Nothing on `main` substitutes from
  it, and `jobs` has no sudo and no Nix daemon trust (checked by the
  `gcp-worker jobs user stays unprivileged` invariant).
- **CPU quota:** the project-wide `CPUS_ALL_REGIONS` cap is 16. The worker (14)
  and `gcp-builder` (8) cannot run at once. `on-worker` waits up to 30 minutes
  for the builder to power off (`ON_WORKER_QUOTA_WAIT`, seconds), and
  `validate.sh` builds locally with a warning while a job holds the quota. API
  quota requests for 32 and 24 were auto-denied on 2026-11-19; once a console
  request is granted, set `worker_machine_type = "c2d-highcpu-16"` in
  `infra/variables.tf` and apply with the VM stopped.

## Using it

```bash
cd ~/code/some-repo
on-worker run -n calib -- uv run python scripts/calibrate.py --workers 14
on-worker status            # every job, newest first
on-worker logs -f calib     # follow; exits with the job's status
on-worker pull results/     # copy outputs back into this checkout
on-worker run -w -- make test   # wait in the foreground
```

- The checkout's tracked files plus untracked, non-ignored files are synced to
  `~jobs/work/<repo>-<hash>`, which persists between runs (`.venv`, caches).
  Add gitignored inputs with `-i PATH`. Symlinks that point outside the
  checkout are copied as their targets, since they would dangle on the worker.
  Sync never deletes remote files.
- Jobs are `systemd-run --user` units named `worker-job-<name>`, bounded by
  `--max-runtime` (default 24h). Logs, command and exit status live in
  `~jobs/jobs/<name>/`.
- When a job ends, `worker-job` posts to the private ntfy topic.
  `on-worker run` copies the topic URL from `main`'s sops secret to
  `~jobs/.config/worker/notify-url` each time.

## Idle shutdown

`worker-idle-shutdown.timer` (from `modules/nixos/profiles/gce-on-demand.nix`)
checks every 5 minutes. A `worker-job-*` cgroup with a live process or an
established port-22 connection counts as active. 20 minutes after neither is
seen, it powers off.

## Provisioning (operator-only)

1. Tailscale: apply the ACL (`bash scripts/apply-tailscale-acl.sh`, which adds
   `tag:worker`). Mint a **reusable, non-ephemeral, pre-approved** auth key
   tagged `tag:worker` and stage it at `<dir>/var/lib/tailscale-authkey` (0600).
2. `cd infra && tofu plan && tofu apply` (creates `gcp-worker` and its Tailscale
   UDP rule).
3. Open a temporary SSH hole, as for the builder:
   `gcloud compute firewall-rules create gcp-worker-provision-ssh --network=default --direction=INGRESS --action=ALLOW --rules=tcp:22 --target-tags=gcp-worker --priority=400 --source-ranges="$(curl -fsS -4 ifconfig.me)/32"`
4. Install, building on the VM itself:
   `nix run github:nix-community/nixos-anywhere -- --flake .#gcp-worker --target-host bootstrap@<ip> --build-on remote --extra-files <dir>`
5. Confirm `tailscale status | grep gcp-worker`, then remove the
   `bootstrap-ssh-public-key` and `startup-script` metadata, delete the firewall
   hole, and shred the staged key (same commands as the builder runbook, step 6).

Ongoing updates: start it (`on-worker start`), then `deploy '.#gcp-worker'`.

## Gotchas

- **Reprovisioning changes the SSH host key.** Clear the stale `known_hosts`
  entry for `gcp-worker.<tailnet>` on `main`.
- **No console password.** Recover a wedged worker by reprovisioning.
- **Not spot.** A reclaim would kill hours-long jobs.
