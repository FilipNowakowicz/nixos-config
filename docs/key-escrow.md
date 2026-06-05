# Personal Age Key Escrow & Recovery

The personal age key (`&user` in [`.sops.yaml`](../.sops.yaml), stored at
`~/.config/sops/age/keys.txt` on `main`) is the **root secret** for this
repository: it is a recipient on every `creation_rules` group, so it decrypts
every encrypted file in the repo. Each host also holds its own SSH-derived age
identity, but those decrypt only that host's own secrets — only the personal key
opens everything.

Losing it is a quiet catastrophe. Deployed hosts keep running (they boot from
their own host keys), but you can no longer edit any secret, add a host, rotate
credentials, or rebuild secrets from scratch. Critically, the loss is
**self-reinforcing**: the personal key _is_ copied into the B2 backup
(`/home/user/.config/sops` is a backed-up path), but reading that backup requires
the restic password, which is itself a sops secret encrypted to the personal key.
The backup copy sits behind a door only the lost key opens. That circular
dependency is why an **out-of-band** escrow copy — outside the sops/restic system
entirely — is required.

See [`docs/security.md`](security.md) for the broader secrets model and key
rotation procedure.

---

## What is escrowed

Exactly one thing: the contents of `~/.config/sops/age/keys.txt` — in practice a
single line beginning `AGE-SECRET-KEY-1…`. That string is the whole master key.

Nothing else needs out-of-band storage. The _encrypted_ secrets already live in
the repo, and the restic/B2 password is one of those encrypted files — so
**escrowed key + a clone of this repo = the ability to decrypt everything**,
including regaining access to B2.

## Where it is escrowed

Store the key in at least two independent locations, neither of which fails
together with `main`:

1. **Vaultwarden** — as a secure note. Reachable from any Bitwarden client; the
   clients keep an offline-cached copy, so the key survives even if
   `homeserver-gcp` (which hosts Vaultwarden) is down.
2. **Paper, offline** — written down and kept in a safe/drawer. Immune to any
   digital failure, ransomware, or correlated outage. The key is short enough to
   transcribe by hand.

Treat the escrow copy with the same care as the live key: anyone holding it can
decrypt every repo secret. Store it encrypted-at-rest or physically secured.

## Verify the escrow actually works

An untested backup is a hope, not a backup. After saving, confirm the escrowed
copy decrypts — using the saved copy, not the live key:

```sh
# Paste the escrowed key into a temp file (not the live keyfile path).
install -m600 /dev/null /tmp/age-escrow-test.txt
$EDITOR /tmp/age-escrow-test.txt          # paste the AGE-SECRET-KEY-1… line

# Decrypt any repo secret using only the escrowed key.
SOPS_AGE_KEY_FILE=/tmp/age-escrow-test.txt sops -d hosts/main/secrets/secrets.yaml >/dev/null \
  && echo "escrow OK" || echo "escrow FAILED — re-copy the key"

shred -u /tmp/age-escrow-test.txt
```

`escrow OK` means the escrowed string is a faithful, working copy.

---

## Recovery: from a blank machine to a working operator

Scenario: `main` is gone and the live `~/.config/sops/age/keys.txt` is lost. You
have the escrowed key and (optionally) a Bitwarden client.

1. **Retrieve the key.** Read the `AGE-SECRET-KEY-1…` line from Vaultwarden or the
   paper copy.

2. **Install it.** On the recovery machine:

   ```sh
   mkdir -p ~/.config/sops/age
   install -m600 /dev/null ~/.config/sops/age/keys.txt
   $EDITOR ~/.config/sops/age/keys.txt      # paste the key line
   ```

3. **Clone the repo.** It holds every encrypted secret and the flake.

   ```sh
   git clone <repo-url> nix && cd nix
   ```

4. **Confirm you can decrypt.** Any secret will do:

   ```sh
   sops -d hosts/main/secrets/secrets.yaml >/dev/null && echo "decrypt OK"
   ```

   From here every secret is readable — including `hosts/main/secrets/`
   restic repository/password/B2 credentials, so the off-site backup is now
   reachable for full data recovery.

5. **Rebuild.** Bring up the host (`nh os switch --hostname main .`, alias
   `rebuild`); deploy others per their host runbooks. Hosts that still hold their
   own host key need nothing further; a host rebuilt from scratch follows its
   provisioning runbook under `hosts/<name>/CLAUDE.md`.

6. **Rotate afterward.** An escrow key that has been taken out of the safe and
   used in a recovery should be considered exposed. Generate a fresh personal key,
   update `&user` in `.sops.yaml`, re-encrypt every secret, and re-escrow:

   ```sh
   age-keygen -o ~/.config/sops/age/keys.txt          # new personal key
   # update the &user public key in .sops.yaml, then:
   find hosts home -path '*/secrets/*' -type f -exec sops updatekeys -y {} +
   ```

   Then redeploy so hosts pick up the re-encrypted material, and replace the
   escrowed copies (Vaultwarden + paper) with the new key.

---

## When to re-escrow

Re-run the escrow steps whenever the personal key changes: after a planned
rotation, after any suspected exposure (per the rotation guidance in
[`docs/security.md`](security.md)), or after a recovery that used the escrow copy.
The escrowed key is only as good as its freshness — a stale escrow copy decrypts
nothing once the live key has rotated.
