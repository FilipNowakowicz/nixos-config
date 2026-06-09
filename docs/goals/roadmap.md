# Roadmap & Backlog

Forward-looking work only. Completed goals are removed once their durable docs
or code paths exist. Each remaining item should say either why it is active now
or what trigger would justify revisiting it.

Host-specific MacBook follow-ups live in
[`macbook-goals.md`](macbook-goals.md).

---

## Active Candidates

| Area   | Item                      | Why active now                                                                                                                  |
| :----- | :------------------------ | :------------------------------------------------------------------------------------------------------------------------------ |
| Public | Public adoption packaging | The repo is being positioned as reusable public NixOS infrastructure, tracked in [`public-adoption.md`](../public-adoption.md). |

---

## Deferred Until Triggered

Real ideas that should stay parked until there is a concrete need.

| Area       | Item                                                                | Trigger to revisit                                                                                    |
| :--------- | :------------------------------------------------------------------ | :---------------------------------------------------------------------------------------------------- |
| Desktop    | `config.specialisation` alternate boot entries, such as gaming mode | A second concrete boot profile is wanted.                                                             |
| Homeserver | Service-level disk quotas                                           | A service shows unbounded disk growth.                                                                |
| Homeserver | Grafana visibility for secret-age metadata                          | Rotation drift becomes a real concern.                                                                |
| GCP        | Metadata endpoint hardening                                         | Metadata-sourced secrets or SSRF exposure becomes a concern.                                          |
| GCP        | Dedicated network / VPC model                                       | More than one provider service needs network separation.                                              |
| Deploy     | Automatic `main` workstation rollout                                | The workstation deploy path becomes safe enough to automate without broadening sudo or recovery risk. |

---

## Deferred Strategic Work

### Cross-System / Multi-Arch Support

Postponed until the first non-`x86_64-linux` host is planned or added. Per-host
`system` metadata already lives in `lib/hosts.nix`; broadening checks now would
add CI and tooling complexity before there is a concrete second architecture to
validate.

Scope when revisited:

- `nix flake check --all-systems`
- `aarch64-linux` evaluation readiness
- Gating or refactoring x86-specific VM and test tooling

Trigger: a real ARM host is planned or added to `lib/hosts.nix`.

### Full Service Composition DSL

A DSL that emits Nginx locations, firewall rules, backup paths, hardening, and
Alloy scrape config could be useful, but premature abstraction would hide
important security and exposure decisions.

Trigger: two or three additional services repeat the same cross-cutting pattern
and the manual edits become error-prone.

### AppArmor Or Broader MAC Policy

Mandatory access control can be valuable but has a high tuning and maintenance
cost. The current security model gets more immediate value from systemd
sandboxing, service-exposure discipline, and restore verification.

Trigger: a specific threat model or service requires confinement beyond systemd
hardening.

### Cloud KMS / Cloud DNS

Speculative for a tailnet-only personal homeserver. Default GCP-managed
encryption and Tailscale DNS cover current needs.

Trigger for KMS: a concrete compliance, key-separation, or rotation-control
requirement.

Trigger for DNS: a real public/private/split-horizon naming problem Tailscale
DNS cannot solve cleanly.

---

## Settled / Won't-Do

Recorded so they are not re-proposed.

- **Migrate Neovim to `programs.neovim`** — won't-do. The bespoke `my.neovim`
  module has language packs, a Lua-config generator, and per-language LSP/DAP
  wiring. It already installs config declaratively via `xdg.configFile."nvim"`
  with no out-of-band injection. Migrating would regress functionality. Reopen
  only if the custom generator becomes a maintenance burden.
