# Security Policy

This is personal NixOS infrastructure published as a reference. It is not a
distributed product with versioned releases, so there is no formal supported-
version matrix.

## Reporting a Vulnerability

If you find a security-relevant issue — for example, a misconfigured systemd
hardening profile, a leaked secret in committed history, or a sops recipient
that grants access too broadly — please report it privately rather than
opening a public issue.

Email: **filip.nowakowicz@gmail.com**

Please include:

- A clear description of the issue and the affected file(s) or host(s).
- Steps to reproduce, if applicable.
- Your assessment of the impact.

I will acknowledge receipt within a few days and follow up with a fix or a
reasoned explanation of why the behaviour is intentional.

## Out of Scope

- Findings in third-party dependencies pulled in via `flake.lock` — please
  report those upstream (nixpkgs, sops-nix, deploy-rs, etc.).
- Hardening choices that are documented as deliberate trade-offs (see
  `docs/security.md`, the `hosts/*/CLAUDE.md` runbooks, and inline comments
  on `services.hardened.*` relaxations).
