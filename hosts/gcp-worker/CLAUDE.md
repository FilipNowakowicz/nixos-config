# gcp-worker Host

Status: **retired** (#592). `on-worker` jobs now run on `gcp-builder` as its
unprivileged `jobs` user, next to its builds; see
[`hosts/gcp-builder/CLAUDE.md`](../gcp-builder/CLAUDE.md#batch-jobs). The
project's 16-vCPU `CPUS_ALL_REGIONS` cap could not hold this VM (14 vCPU) and
the builder at once, so one of them always waited or failed.

The VM stays **stopped** and its disk kept until old job results have been
pulled. To fetch something from it:

```bash
gcloud compute instances start gcp-worker --zone europe-west2-c
scp -r jobs@gcp-worker.tail90fc7a.ts.net:work/<repo>-<hash>/results ./
gcloud compute instances stop gcp-worker --zone europe-west2-c
```

Do not start it while `gcp-builder` runs: together they exceed the CPU cap.
A follow-up removes this host, its registry entry, `tag:worker` and
`infra/worker.tf`. The previous runbook is in git history.
