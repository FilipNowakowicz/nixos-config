locals {
  name = "homeserver-gcp"
}

# ── Firewall ─────────────────────────────────────────────────────────────────

resource "google_compute_firewall" "tailscale" {
  name        = "${local.name}-tailscale"
  network     = "default"
  description = "Allow Tailscale UDP inbound for ${local.name}"

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }

  target_tags   = [local.name]
  source_ranges = ["0.0.0.0/0"]
}

# ── VM instance ──────────────────────────────────────────────────────────────

resource "google_compute_instance" "homeserver_gcp" {
  name         = local.name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = [local.name]

  boot_disk {
    initialize_params {
      image = "projects/${var.bootstrap_image_project}/global/images/family/${var.bootstrap_image_family}"
      size  = var.disk_size_gb
      type  = "pd-ssd"
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    # Temporary bootstrap access for nixos-anywhere. The startup script installs
    # this key into a temporary sudo-capable bootstrap account.
    bootstrap-ssh-public-key = var.bootstrap_ssh_public_key

    # Pre-baked SSH host key for sops bootstrap — consumed by the
    # injectGceSshHostKey activation script on first boot.
    # The key is only needed until Tailscale is up; remove it afterwards:
    #   gcloud compute instances remove-metadata homeserver-gcp --keys=ssh-host-key-b64
    ssh-host-key-b64 = var.ssh_host_key_b64

    # Enable GCE serial console login for emergency recovery.
    serial-port-enable = "TRUE"

    startup-script = <<-EOT
      #!/bin/bash
      set -euo pipefail

      BOOTSTRAP_KEY="$(curl -fsS -H 'Metadata-Flavor: Google' \
        http://metadata.google.internal/computeMetadata/v1/instance/attributes/bootstrap-ssh-public-key)"

      if ! id -u bootstrap >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash bootstrap
      fi

      install -d -m 700 -o bootstrap -g bootstrap /home/bootstrap/.ssh
      printf '%s\n' "$BOOTSTRAP_KEY" > /home/bootstrap/.ssh/authorized_keys
      chown bootstrap:bootstrap /home/bootstrap/.ssh/authorized_keys
      chmod 600 /home/bootstrap/.ssh/authorized_keys

      printf 'bootstrap ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/90-bootstrap
      chmod 440 /etc/sudoers.d/90-bootstrap

      systemctl reload ssh || systemctl reload sshd || true
    EOT
  }

  lifecycle {
    ignore_changes = [
      metadata["ssh-host-key-b64"],
    ]
  }
}
