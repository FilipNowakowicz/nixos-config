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

