## Sops Bootstrap

Pre-baked host SSH key is committed encrypted to the repo.

- Private key: `hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.enc`
- Public key: `hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.pub.enc`
- Age identity: `&homeserver_gcp_host` in `.sops.yaml`

`nix build '.#checks.x86_64-linux.homeserver-gcp-sops-bootstrap'` verifies both files are present.

The pre-baked key is injected into the installed root outside OpenTofu state:

1. `scripts/deploy-gcp.sh` decrypts the key into a local temporary directory.
2. OpenTofu creates only the temporary bootstrap SSH account metadata; the host private key is never passed as a variable, output, or metadata value.
3. The script installs the expected host key on the bootstrap VM, rescans SSH, and aborts unless the scanned Ed25519 key equals the decrypted public key.
4. `nixos-anywhere --extra-files` copies the key into `/etc/ssh/ssh_host_ed25519_key` in the installed NixOS root before first boot.
5. The local decrypted temporary copy is removed by the script exit trap.

No manual key injection step is needed.

## Provisioning

Provisioning is end-to-end automated via `scripts/deploy-gcp.sh`:

```bash
nix develop                          # provides sops, opentofu, nixos-anywhere, gcloud
bash scripts/deploy-gcp.sh           # plan + apply (interactive)
bash scripts/deploy-gcp.sh -auto-approve
bash scripts/deploy-gcp.sh -destroy  # tear down bootstrap infra
```

The script:

1. Decrypts the pre-baked SSH host key.
2. Runs `tofu apply` to create the GCE VM with the operator's temporary bootstrap pubkey.
3. Waits for SSH to come up.
4. Installs and verifies the expected Ed25519 SSH host key before invoking `nixos-anywhere`.
5. Runs `nixos-anywhere --flake '.#homeserver-gcp' --extra-files <host-key-dir>` to install NixOS over the bootstrap image.
6. Removes and verifies removal of all bootstrap-only metadata keys.

Before the first run, copy `infra/terraform.tfvars.example` to `infra/terraform.tfvars` and fill in the GCP project ID.

## First Deploy Checklist

When provisioning from scratch:

1. **Fill in real secrets** — `sops hosts/homeserver-gcp/secrets/secrets.yaml`, set:
   - `tailscale_auth_key` — Tailscale admin → Settings → Keys → reusable + ephemeral
   - `user_password` — bcrypt hash: `mkpasswd -m bcrypt`
   - `grafana_admin_password`, `grafana_secret_key`, `observability_ingest_htpasswd`
   - `alertmanager_webhook_url` — off-host notification URL such as an ntfy topic
   - `restic_password`, `b2_credentials` (env-file format: `B2_ACCOUNT_ID=…` / `B2_ACCOUNT_KEY=…`)

2. **Provision the VM + install NixOS** — `bash scripts/deploy-gcp.sh` (see above).

3. **Wait ~60s for first boot** — sops decrypts secrets, Tailscale joins the tailnet.

4. **Confirm reachability** — `tailscale status | grep homeserver-gcp`.

5. **Bootstrap metadata cleanup is automatic** — `deploy-gcp.sh` removes and verifies the temporary bootstrap pubkey and startup script metadata after a successful install. OpenTofu ignores those bootstrap-only metadata keys on later applies so they are not recreated after cleanup.

6. **Create Vaultwarden account** — temporarily set `SIGNUPS_ALLOWED = true`, deploy, sign up, set back to `false`, redeploy.

7. **Set up AdGuard Home** — open `http://<tailscale-ip>:3001` in a browser and complete the setup wizard (create admin user, confirm DNS on port 53). Then in Tailscale admin → DNS → Nameservers, add the homeserver-gcp Tailscale IP as a global nameserver.
