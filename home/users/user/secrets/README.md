User-scoped auth backups for the Home Manager `sops-nix` module live here.

Managed files in this directory:

- `codex-auth.json`
- `claude-credentials.json`
- `gemini-oauth_creds.json`
- `gh-hosts.yaml`
- `gcloud-application_default_credentials.json`
- `user-identity.yaml`

If any of these files are committed, they must be `sops`-encrypted first. The
matching Home Manager declarations are in `home/users/user/secrets.nix`.
