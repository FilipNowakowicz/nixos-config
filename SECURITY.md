# Security Boundary

This repository is personal NixOS infrastructure published as a reference. It is
not a reusable distribution, and it does not have supported release lines.

Security-sensitive changes should preserve these boundaries:

- Secrets committed to the repository must be encrypted with `sops`.
- Private keys, decrypted auth files, live service credentials, and recovery
  material must stay out of git history.
- Host-specific secrets should only be decryptable by the intended operator or
  host recipients in `.sops.yaml`.
- Network exposure should stay explicit. Public listeners, Tailscale listeners,
  initrd SSH, and firewall openings are security-relevant changes.
- Passwordless sudo should remain narrow and command-specific.
- Persistent paths on impermanent hosts should be treated as part of the trusted
  state model, not as incidental storage.
- Backup coverage and restore paths are part of the security model; identity
  material needed after reinstall should be deliberately included or excluded.

The detailed model lives in:

- `docs/security.md` for secrets, host identity, network exposure, hardening,
  audit logs, and backups.
- `.sops.yaml` for age recipient ownership.
- `home/users/user/secrets/README.md` for user-scoped auth backups.
- `hosts/*/CLAUDE.md` for host-local operational notes.
