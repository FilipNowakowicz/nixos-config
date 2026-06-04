locals {
  name = "homeserver-gcp"

  snapshot_storage_locations = length(var.snapshot_storage_locations) > 0 ? var.snapshot_storage_locations : [var.region]
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

# The "default" network auto-creates default-allow-ssh (TCP/22 from 0.0.0.0/0)
# at priority 65534, which exposes the public NAT IP to the internet. SSH is
# meant to be tailnet-only, so this higher-precedence deny (lower priority
# number) blocks public TCP/22 at the GCP edge as defense-in-depth alongside
# the in-guest nftables rule.
#
# NOTE: apply manually (NOT via terraform apply in this change):
#   cd infra && tofu plan && tofu apply
resource "google_compute_firewall" "deny_public_ssh" {
  name     = "deny-public-ssh"
  network  = "default"
  priority = 500

  deny {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

# ── Disk snapshots ───────────────────────────────────────────────────────────

resource "google_compute_resource_policy" "homeserver_boot_daily_snapshots" {
  name        = "${local.name}-boot-daily-snapshots"
  region      = var.region
  description = "Daily snapshots for fast rollback of the ${local.name} boot disk. Restic/B2 remains the off-site application backup."

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = var.snapshot_start_time
      }
    }

    retention_policy {
      max_retention_days    = var.snapshot_retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }

    snapshot_properties {
      storage_locations = local.snapshot_storage_locations

      labels = {
        host    = local.name
        purpose = "fast-rollback"
        backup  = "provider-local"
      }
    }
  }
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
      type  = var.disk_type
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  # Shielded VM: vTPM gives a hardware root of trust and integrity monitoring
  # baselines the boot measurements so tampering shows up in the Compute Engine
  # integrity report.
  #
  # Secure Boot is deliberately OFF: stock NixOS does not produce signed boot
  # artifacts, so enabling it would leave the VM unbootable until the image
  # adopts lanzaboote-style signing. Revisit enable_secure_boot only alongside
  # signed-boot support.
  #
  # NOTE: changing shielded_instance_config on an existing instance requires the
  # VM to be STOPPED first; `tofu apply` will report this. Apply during a
  # maintenance window (stop VM → apply → start VM), not on the live host.
  shielded_instance_config {
    enable_secure_boot          = false
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    # Temporary bootstrap access for nixos-anywhere. The startup script installs
    # this key into a temporary sudo-capable bootstrap account.
    bootstrap-ssh-public-key = var.bootstrap_ssh_public_key

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

      # Temporary broad sudo for nixos-anywhere. scripts/deploy-gcp.sh removes
      # the metadata that recreates this account after a successful install.
      printf 'bootstrap ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/90-bootstrap
      chmod 440 /etc/sudoers.d/90-bootstrap

      systemctl reload ssh || systemctl reload sshd || true
    EOT
  }

  lifecycle {
    ignore_changes = [
      metadata["bootstrap-ssh-public-key"],
      metadata["startup-script"],
      # Disk type cannot be changed in place on GCE. Pin it so flipping
      # var.disk_type (e.g. the pd-ssd -> pd-balanced default) does not force a
      # destructive replacement of the live, stateful instance; the new default
      # then applies only to freshly provisioned instances.
      boot_disk[0].initialize_params[0].type,
    ]
  }
}

resource "google_compute_disk_resource_policy_attachment" "homeserver_boot_daily_snapshots" {
  name = google_compute_resource_policy.homeserver_boot_daily_snapshots.name
  disk = google_compute_instance.homeserver_gcp.name
  zone = var.zone
}
