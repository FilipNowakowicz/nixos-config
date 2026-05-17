User-scoped auth backups for the Home Manager `sops-nix` module live here.

Planned files:

- `codex-auth.json`
- `claude-credentials.json`
- `gemini-oauth_creds.json`
- `gh-hosts.yaml`
- `gcloud-application_default_credentials.json`

These files should be encrypted with `sops` before they are committed. The
matching Home Manager declarations are in `home/users/user/secrets.nix`.
