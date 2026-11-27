# Disk-loss recovery audit, 23 November 2026

The workstation can complete a daily backup while losing entire projects in a
disk failure. The highest priorities are to protect authoritative working data,
recover the weekly integrity check, and make missing evidence visible. The
homeserver has stronger application recovery evidence, especially for Grafana.
A timed recovery from independent credentials is still outstanding on both hosts.

Scope was checkout `573fb3f`, the running workstation's generated units, path
and mount metadata, journals on both hosts, read-only B2 snapshot metadata, and isolated tests with disposable
data. The existing [inventory](backups.md) supplies the job list and policy.
The [related audit issue](https://github.com/FilipNowakowicz/nixos-config/issues/571)
identifies four weaknesses in the checks. This review also follows application
dependencies through recovery. No production restore or escrow retrieval was
performed.

## What survives losing the workstation disk?

With the disk gone, `@home`, `@persist`, btrbk snapshots and old roots all go
together. For the Restic cases below, the first independent dependency is a
second device with the personal age key from escrow and a readable copy of the
encrypted host configuration. These yield the repository locator, password and
backend credentials. A password manager accessible only through the lost
laptop's second factor would break that route. Only a clean-device test can
establish it works. The host SSH key and personal age key inside the backup
cannot bootstrap access to that same backup. See [key escrow](key-escrow.md).

| Asset on main                                     | After disk loss                                                                                                                                                                                                                                                                                                                     | What would establish usable recovery                                                                                                                                                                                                                                  |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Project checkout outside `~/nix`                  | Its unpushed commits, dirty tree and ignored inputs have no declared off-host copy. An observed local application source tree on `@home` had no Git repository. A separate checkout's branch tips matched its live remote despite stale remote-tracking information.                                                                | Recover a local-only branch and dirty file in scratch. Compare the commit ID and file digest, run `git fsck --full`, then run a project command that consumes the recovered input.                                                                                    |
| Ignored private inputs in an application checkout | Two ignored files were present outside all active Restic roots. Cloning that checkout restores neither file. Independent personal copies are unknown.                                                                                                                                                                               | Compare a restored private input with a pre-recorded digest and open it with its intended reader. Exercise a synthetic equivalent in unattended tests.                                                                                                                |
| Main Nix checkout and linked worktrees            | Restic selects `~/nix`, including its common Git object store and refs. The two linked checkout directories under `~/.local/share/worktrees/nix` are outside selection. Committed objects can survive while uncommitted file contents in the linked trees disappear.                                                                | Restore the common repo, recover the expected branch, reconstruct the worktree and verify a previously unstaged marker in it.                                                                                                                                         |
| Anki profiles                                     | The active selection includes `~/.local/share/Anki2`. Two collection files and 19 automatic collection packages were present. A live filesystem walk gives no common capture instant across collection, WAL and media. Automatic Anki backups omit media.                                                                           | Open an isolated restored profile with sync off. Check a known card, its scheduling and referenced media. A fallback is an Anki collection export with media. [Anki backup manual](https://docs.ankiweb.net/manual/backups)                                           |
| Browser and VMs                                   | Selected browser profiles and libvirt state are read while writers may be active. VM disk images can depend on backing files. Main persists `/var/lib/systemd/credential.secret` for libvirt's encrypted secrets, but the active Restic selection omits it. Its loss previously broke libvirt startup according to the host module. | Open a restored browser offline and check a known bookmark. For a VM, verify the complete backing chain, recover or regenerate its credential dependencies, start its domain in isolation and verify a guest file. [Host persistence](../hosts/main/impermanence.nix) |

Anki Generator has a separate recovery boundary. Its default review workspace
at `~/anki-generator/local/workspace/state.sqlite3` exists, is Git-ignored
and falls outside Restic. The delivered cards in Anki cannot reconstruct the
pending proposals, review decisions and delivery records held there. The
generator's normal export and restore commands round-tripped a synthetic demo
through an empty workspace with identical exported cards, review, exchanges and
delivery data. Include its export and required private source inputs in the
off-host coverage decision.

The source tree without Git was `~/workout_app`. The private input example was
`~/internship-applications/Transcripts`. Only file counts and Git metadata
were inspected for the private inputs. Future coverage should include approved
project roots and the linked-worktree root, or place them inside a protected
workspace. Confirm inclusions per project before excluding caches, reproducible
environments and generated outputs. A broad rule excluding all Git-ignored
files would lose precisely the private inputs in this sample.

## Evidence from both hosts

- **Workstation backup.** The 23 November journal recorded snapshot
  `1e588826` and a successful unit finish at 00:03 UTC. Forget reported 11
  kept snapshots with dates spanning 30 September to 23 November. Using the checkout and the local operator identity, a read-only B2 query
  independently confirmed all 11 snapshots and the newest ID. Its Anki index
  contained 2 collections, 19 backup packages and 536 files under media directories.
  These are directory entries. Production payloads and independent escrow
  remain untested.
- **Workstation integrity.** Five weekly runs from 26 October through 23
  November failed in the pre-start repository probe. The latest consumed
  6 minutes 15 seconds before exiting. The probe discards the underlying
  error and reports “unreachable” for every failure. Failure cause remains
  unknown. A good daily write alongside a failed weekly probe warrants comparing
  the units' actual backend, environment, executable paths and failure classes
  before adjusting network waits. The weekly data read never started on those runs.
- **Monitoring after reboot.** Both workstation Restic timestamp files were
  absent during inspection. The [host runbook](../hosts/main/CLAUDE.md)
  intentionally places them on the rolled-back root. The four [freshness
  alerts](../lib/observability-alerts.nix) compare the age of existing series.
  Once a series is absent, that expression yields no alert for it. Preserve
  last-good evidence across boots and alert per expected host and job for a
  missing series. Test a reboot followed by a failed first run as well as a
  stale timestamp. A daily backup alert alone cannot detect failed weekly checks.
- **Homeserver.** The latest successful backup, integrity check and daily
  canary stamps corresponded to 22 November 23:01, 23 November 00:53 and
  03:56 UTC. Forget reported 23 kept snapshots spanning 7 May to 23 November.
  The canary reads the static marker and validates a restored Grafana database.
  Its timestamp measures when those reads worked; today’s check can pass on an
  older snapshot. Inspect backup age separately.
- **Quarterly service drill.** The deployed timer was active, next due
  1 January 2027, with an empty last-trigger field, no success stamp, and no
  completion in the available drill journal. This establishes a scheduled
  drill and no observed pass. The configured tests open Grafana's restored DB
  and exercise AdGuard's HTTP and DNS listeners. An isolated DNS response can
  be SERVFAIL. A known local rewrite or filter decision would demonstrate
  recovered policy. The corrected manual AdGuard path and cutover were exercised locally with a staged marker, a symlinked destination and an intact rollback copy. GCE disk snapshots provide another rollback route whose
  creation, IAM and recovery into a replacement VM were not exercised.
- **Batch-job outputs and other copies.** `on-worker` jobs run on
  `gcp-builder`, whose job workspaces survive ordinary power-off but have no
  declared backup. Pull irreplaceable outputs into a protected location before
  treating the builder as disposable; otherwise it can be reprovisioned. The
  retired `gcp-worker` was archived to the laptop before removal (#594). No
  evidence was collected about independent copies in other accounts.
  [Builder runbook](../hosts/gcp-builder/CLAUDE.md#batch-jobs)

## Which failures can the checks catch?

| Requirement and owner                                      | Evidence today                                                                                                                                                                                                                                                                                                                                         | Missing proof                                                                                                                                                                                                                       |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Workstation inputs and excludes, main backup module        | Evaluation requires three literal roots. A disposable restore with the deployed include and exclude lists recovered SSH, Nix and Anki markers. The gcloud credential marker and both unselected project markers were absent as expected. Adding SSH to the exclusions removed the SSH marker while the required path still appeared in the input list. | Assert representative restored contents, including negative controls and project-specific private inputs.                                                                                                                           |
| Rollback survival, main impermanence and filesystem owners | The live examples above reside on the `@home` mount. SSH host key, machine ID and systemd credential secret resolved to individual `@persist` binds. The evaluation check accepts any matching persistent ancestor. A deeper volatile mount can hide beneath it.                                                                                       | Resolve the most specific mount or binding and exercise a saved marker across an actual disposable rollback boot, including a tmpfs shadowing a persistent parent. [Filesystem check](../hosts/main/checks.nix)                     |
| Catch-up, main backup and check service owners             | A disposable local repository began unavailable. Using the deployed probe followed by the generated backup pre-start and real backup binary, the same invocation sequence backed up after the repo returned. A continuously unavailable repo exhausted 30 attempts and blocked initialization.                                                         | Fixture paths and sleep duration were substituted. This did not reproduce systemd suspend, B2, or the deployed weekly unit failure. Add separate backup and integrity cases, plus an independently successful no-op probe mutation. |
| New repository bootstrap, main backup owner                | The deployed first probe requires a readable repository config. The generated second pre-start initializes an absent repo only after the probe succeeds. A genuinely empty destination cannot pass this order.                                                                                                                                         | Decide whether repository creation is a deliberate operator step. Distinguish an empty destination from an existing one that has become inaccessible before enabling any initialization.                                            |
| Historical recovery, retention policy owner                | Critical policy is independently pinned to 14 daily, 8 weekly, 6 monthly and 2 yearly in the flake check. Host grouping spans changes to the input list. A scratch run applied the critical flags to 18 dated snapshots across two path lists. It retained 16, dropped 2 and 3 November, and restored the previous December’s file by ID.              | Preserve the independent oracle and turn the dated fixture into a repeatable regression test. The oldest usable production recovery point still requires a read. [Policy](../lib/backup-policy.nix)                                 |
| Application usability, application and recovery owners     | A closed synthetic collection went through local Restic and reopened with the installed Anki 26.09.4 backend. Its card and referenced media bytes matched. The homeserver daily canary validates Grafana's SQLite backup.                                                                                                                              | Real Anki capture during writes, real media recovery, independent key access, browser state, VM boot, and elapsed end-to-end restoration on replacement hardware.                                                                   |

## Remediation order and acceptance

1. **Restore integrity visibility.** Diagnose the weekly failure with a
   redacted backend error and record one successful deployed check. Preserve
   success timestamps across rollback and exercise missing-series alerts on
   both hosts, including the first quarterly drill. Keep backup, check and
   restore outcomes individually visible.
2. **Define workstation coverage.** Choose the authoritative project, document
   and worktree roots and a deliberate strategy for VM credentials. Estimate
   storage and initial upload before extending policy. Measure freshness from
   the newest recoverable piece of work. A proposed starting objective is at
   most 24 hours of lost work while regularly connected. Show overdue status
   while offline and catch up on reconnection. Daily plus jitter alone cannot
   guarantee a strict rolling 24-hour bound.
3. **Prove a workstation recovery.** Use a clean recovery device, Git checkout
   and independent escrow. Select one snapshot ID, restore to encrypted
   scratch, open the project and Anki offline, verify a known private input
   and media, then record the oldest missing change and elapsed time. Test an
   older recovery point too. A first timed drill should establish a realistic
   recovery-time target.
4. **Exercise the other failure domains.** Run the isolated homeserver service
   drill and verify a known local DNS rule. Decide whether losing the machine,
   the cloud account, or deletion by a credential used for ordinary backups
   must each be survivable. Check actual backend permissions, ownership,
   independent recovery access and retention enforcement before making that
   claim. Decide whether telemetry and worker outputs warrant off-provider
   retention. Test a separate GCE disk restore if whole-VM recovery is an objective.

These are scoped remediation items for the existing audit issue. Production
policy, CI placement, B2 lifecycle and credential changes require their own
implementation and acceptance evidence.
