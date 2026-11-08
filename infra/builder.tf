# ── On-demand Nix remote builder ─────────────────────────────────────────────
#
# A normally-stopped build box that `main` starts on demand (and that shuts
# itself down when idle, see hosts/gcp-builder). It is NOT a spot/preemptible
# instance: a reclaim mid-build would kill long `validate.sh heavy` runs, so it
# is a standard instance whose power state is driven by start/stop rather than
# Terraform.
#
# n2 family + nested virtualization is required so the box can run the
# KVM-backed nixos test suite; the e2 family does not support nested virt.
#
# NOTE: apply manually (NOT via terraform apply in this change):
#   cd infra && tofu plan && tofu apply

locals {
  builder_name = "gcp-builder"
}

# Tailscale UDP inbound for the builder (mirrors the homeserver rule, separate
# resource so this file stays self-contained). Public SSH stays blocked by the
# network-wide deny_public_ssh rule in main.tf.
resource "google_compute_firewall" "builder_tailscale" {
  name        = "${local.builder_name}-tailscale"
  network     = "default"
  description = "Allow Tailscale UDP inbound for ${local.builder_name}"

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }

  target_tags   = [local.builder_name]
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_instance" "gcp_builder" {
  name              = local.builder_name
  machine_type      = var.builder_machine_type
  zone              = var.zone
  tags              = [local.builder_name]
  resource_policies = [google_compute_resource_policy.builder_weekly_prebuild.self_link]

  # Nested virtualization so the builder can advertise the "kvm"/"nixos-test"
  # Nix system-features and run booted NixOS tests offloaded from `main`.
  advanced_machine_features {
    enable_nested_virtualization = true
  }

  boot_disk {
    initialize_params {
      image = "projects/${var.bootstrap_image_project}/global/images/family/${var.bootstrap_image_family}"
      size  = var.builder_disk_size_gb
      type  = var.disk_type
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    # Temporary bootstrap access for nixos-anywhere (same flow as homeserver).
    bootstrap-ssh-public-key = var.bootstrap_ssh_public_key
    serial-port-enable       = "TRUE"

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
      metadata["bootstrap-ssh-public-key"],
      metadata["startup-script"],
      # Power state is managed out-of-band (gcloud start/stop + the in-guest
      # idle-shutdown timer); never let Terraform fight the start/stop loop.
      desired_status,
      # Disk type cannot change in place; pin like the homeserver instance.
      boot_disk[0].initialize_params[0].type,
    ]
  }
}

# Friday lock updates start at 18:00 UTC; build whatever reached main by 20:00.
data "google_project" "builder_schedule" {
  project_id = var.gcp_project
}

# GCE instance schedules act through the Compute Engine service agent.
resource "google_project_iam_member" "builder_schedule" {
  project = var.gcp_project
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:service-${data.google_project.builder_schedule.number}@compute-system.iam.gserviceaccount.com"
}

resource "google_compute_resource_policy" "builder_weekly_prebuild" {
  name   = "gcp-builder-weekly-prebuild"
  region = var.region
  instance_schedule_policy {
    time_zone = "Etc/UTC"
    vm_start_schedule {
      schedule = "0 20 * * 5"
    }
  }
  depends_on = [google_project_iam_member.builder_schedule]
}

# GitHub CI wakes the builder with this account. Its key is created outside
# Terraform so it never enters state, and its only role is on this one VM.
resource "google_service_account" "ci_builder_start" {
  account_id   = "ci-builder-start"
  display_name = "CI: start gcp-builder"
}

resource "google_compute_instance_iam_member" "ci_builder_start" {
  zone          = var.zone
  instance_name = google_compute_instance.gcp_builder.name
  role          = "roles/compute.instanceAdmin.v1"
  member        = "serviceAccount:${google_service_account.ci_builder_start.email}"
}
