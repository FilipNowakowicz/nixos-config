---
name: nix-verification-loop
description: Use for changes in this NixOS flake to select and run the smallest meaningful validation command before broader checks.
---

# Nix Verification Loop

Use this workflow whenever editing Nix, shell scripts, host definitions, tests,
packages, deploy wiring, secrets boundaries, or generated data in this repo.

## Workflow

1. Identify the touched surface:
   - Flake/module wiring: start with `bash scripts/validate.sh flake-eval`.
   - Shared modules/profiles/lib helpers: add `bash scripts/validate.sh light`.
   - A single host: run `bash scripts/validate.sh host <name>` when closure risk matters.
   - Package outputs: run `bash scripts/validate.sh package <name>` or `package all`.
   - Profile behavior: run `bash scripts/validate.sh profile-test <name>`.
   - Homeserver routing: run `bash scripts/validate.sh smoke-homeserver-gcp` when endpoint behavior changes.
   - Markdown-only repo docs: run `bash scripts/validate.sh docs`.
2. If new files are created for a Nix flake check or build, stage them before
   expecting Nix to see them.
3. Prefer the narrow check first, then widen only when the touched surface justifies it.
4. Report any skipped validation explicitly with the reason.

## Guardrails

- Do not run deploy commands unless the user asked for deployment or the task
  explicitly requires landing live host state.
- Treat `deploy-rs` silence in non-interactive sessions as a known behavior; if
  necessary, fall back to closure build/copy/switch instructions from `CLAUDE.md`.
- Never edit encrypted secrets directly. Use `sops`.
- Do not use `nix develop -c <tool>` or `nix develop --command <tool>` as proof
  that a non-interactive validation command ran in this repo. The default
  devShell shell hook execs zsh, which can replace the requested command and
  exit successfully with no output. Run tools already available in the current
  shell directly, use `nix fmt -- <files>` for formatter-backed checks when
  appropriate, or run ad-hoc tools explicitly with `nix run`.

## Operational gotchas

- **A successful build is not a live switch.** In non-interactive sessions
  `nh os switch --hostname main .` can build the generation and then fail
  activation with `sudo: a terminal is required to read the password`, leaving
  the new services absent from the running generation. Confirm sudo is usable
  (`sudo -n true`) before claiming a host is switched; if it is not, report the
  build as done and a user-authenticated switch as the remaining step.
- **`deploy-rs` runs broad flake checks before any remote activation.** A
  `deploy '.#homeserver-gcp'` can fail on an unrelated `main-ci` invariant or a
  repo-wide `pre-commit` check (`checks.x86_64-linux.invariants-main-ci`,
  `checks.x86_64-linux.pre-commit`) before the host is ever touched. Treat an
  early "Failed to check deployment" as a full-flake validation blocker: fix the
  named check first, then retry the host deploy.
- **Trust closure CVE scans, not live counts.** For security triage prefer
  `bash scripts/validate.sh cve-reports` (the current flake-built closure) over
  `vulnix_cve_total` from a deployed generation — live counts cause whitelist
  churn and false positives. The live homeserver timer intentionally exports
  only scanner freshness, not raw counts.
- **Never delete a defensive `VAR=` command prefix to silence a linter.**
  shellcheck SC1007 fires on the bare `var= cmd` form, but dropping `CDPATH=`
  from `script_dir=$(cd -- … && pwd)` is a regression: with `CDPATH` set in the
  env, `cd <relative>` echoes the resolved path into the capture and corrupts
  it. Rewrite as `CDPATH='' cd -- …` — the guard is preserved and SC1007 stops
  firing.
- **`nix build`/`flake check` only proves a transient unit's definition
  evaluates, not that systemd accepts it at runtime.** Sandbox/namespacing
  directives like `PrivateNetwork=` are service-only — `systemd-run --scope`
  rejects them with "Unknown assignment" at runtime even though the Nix
  expression type-checks fine (see `hosts/homeserver-gcp/restore-drill.nix`'s
  `runIsolated`, which uses `--pipe --wait` service units instead). Transient
  units also start with systemd's default `PATH` and without the env vars a
  NixOS module would normally inject, so `cat`/`${pkg}/bin/foo` invocations can
  fail in ways a build never surfaces. Any drill or check that spawns
  `systemd-run` units must be smoke-tested by actually starting it on a live
  host.
