# Mutation-testing protocol

Question: when a realistic security or operational misconfiguration is
introduced into this flake, how many of the injected mistakes do the repo's
own fast checks catch?

This file and `mutants.txt` are committed before any mutant is run. The list
is fixed: a mutant is never removed or edited after its result is known.

## Mutants

`mutants.txt` holds 50 mutants. Each is a small source edit (exact
old-text to new-text replacement, old text must match exactly once) that
models one misconfiguration: open SSH, disabled firewall, dropped fail2ban,
widened sudo, weakened systemd hardening baseline, unpersisted or missing
backup, plaintext secret, USBGuard allow-all, Tailscale ACL mistakes, alerting
gaps, and similar. They were chosen from reading the host and module sources,
not from knowledge of which checks exist; several were written knowing a
check probably does not cover them.

Each entry records, before running:

- `area`: the topic.
- `expected layer`: `eval` if an eval-level or build-of-a-small-derivation
  check could plausibly catch it, `vm` if only a booted NixOS test could.
- `expected check(s)`: the check I expect to fail, or "none expected to be
  specific" where I do not know of one.

Mutants are applied by `tests/mutation/apply.py` to the worktree only and
reverted with `git checkout`. Plaintext-secret mutants use obviously fake
values. No mutant touches real infrastructure.

## Exclusion rule

A mutant may be excluded only if, after applying it, the flake fails to
evaluate for a reason unrelated to the intended misconfiguration (for
example the edit breaks Nix syntax or removes an attribute that something
unrelated needs). Excluded mutants are counted and reported with the reason;
they stay in the list. A mutant that evaluates but is rejected by a check, an
assertion or a throw is a catch, not an exclusion.

## Checks covered by the score

`scripts/mutation-test.sh` runs these stages in order and stops at the first
stage that fails. A mutant is "caught" if any stage fails.

Gated stages (what the repo's CI gates run, minus whole-closure builds):

1. `scripts`: `scan-plaintext-secrets.sh`, `check-secrets-directory.sh`.
2. `eval`: evaluation of every `checks.<system>.*` derivation path (this
   includes the `deploy-activate` check, which forces the toplevel of every
   deploy target and so all NixOS assertions), the `main` toplevel path,
   and `packages.<system>.tailscale-acl`. This approximates
   `nix flake check --no-build` without evaluating every output.
3. `light`: build of the checks listed in the `light)` section of
   `scripts/validate.sh`, except `deploy-activate` and `deploy-schema`
   (whole host closures; their evaluation is covered by stage 2).

Ungated stage (reported separately):

4. `extra`: build of every other check that is cheap to build and not wired
   into `light` (for example `invariants-registry-security`,
   `services-hardened`, fixtures).

Headline score = caught by stages 1-3 out of non-excluded mutants.
Secondary score = caught by stages 1-4.

Not covered: VM tests (`tests/nixos/*`), `nix build` of full host closures,
statix/deadnix/treefmt/shellcheck lint, `check-tailscale-acl-drift.sh`
(needs the live tailnet). Mutants whose expected layer is `vm` are in the
denominator and are expected to survive; the report splits the score by
expected layer.

## Procedure

1. Baseline: the unmutated tree must pass every stage, otherwise the score is
   meaningless.
2. BEFORE: run all mutants against the unmodified checks.
3. Fix false-confidence tests from `audits/test-suite-depth-audit-2026-09-18.md`
   and add checks for survivors, minimally.
4. AFTER: rerun the same list. Both scores are reported.

Survivors are reported plainly.
