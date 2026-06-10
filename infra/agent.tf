# ── On-demand Claude Code agent host ─────────────────────────────────────────
#
# A normally-stopped box that runs Claude Code issue-loop sessions (NOT Nix
# builds — heavy builds/tests offload to gcp-builder). Started for a session and
# shuts itself down when idle (see hosts/gcp-agent). Like the builder it is NOT
# a spot/preemptible instance: a reclaim mid-session would drop an in-flight
# orchestration run, so it is a standard instance whose power state is driven by
# start/stop rather than Terraform.
#
# No nested virtualization (the e2 family is fine); unlike the builder it
# carries sops secrets (its own claude login + a scoped GitHub PAT).
#
# NOTE: apply manually (NOT via terraform apply in CI):
#   cd infra && tofu plan && tofu apply

locals {
  agent_name = "gcp-agent"
}

# Tailscale UDP inbound for the agent (mirrors the builder rule, separate
# resource so this file stays self-contained). Public SSH stays blocked by the
# network-wide deny_public_ssh rule in main.tf.
resource "google_compute_firewall" "agent_tailscale" {
  name        = "${local.agent_name}-tailscale"
  network     = "default"
  description = "Allow Tailscale UDP inbound for ${local.agent_name}"

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }

  target_tags   = [local.agent_name]
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_instance" "gcp_agent" {
  name         = local.agent_name
  machine_type = var.agent_machine_type
  zone         = var.zone
  tags         = [local.agent_name]

  boot_disk {
    initialize_params {
      image = "projects/${var.bootstrap_image_project}/global/images/family/${var.bootstrap_image_family}"
      size  = var.agent_disk_size_gb
      type  = var.disk_type
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    # Temporary bootstrap access for nixos-anywhere (same flow as builder).
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
