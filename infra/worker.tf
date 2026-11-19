# ── On-demand batch worker ───────────────────────────────────────────────────
#
# A normally-stopped VM for long CPU-heavy jobs from any repository, started by
# `on-worker` on `main` and powered off by its own idle check once no job is
# running (see hosts/gcp-worker). Not spot: a reclaim would kill hours-long
# jobs. Power state is start/stop, never Terraform.
#
# pd-balanced counts against the regional SSD_TOTAL_GB quota, which the
# builder's zone move also needs room in (one extra copy of its 100 GB disk);
# keep this disk small enough to leave that room.
#
# Apply manually: cd infra && tofu plan && tofu apply

locals {
  worker_name = "gcp-worker"
}

resource "google_compute_firewall" "worker_tailscale" {
  name        = "${local.worker_name}-tailscale"
  network     = "default"
  description = "Allow Tailscale UDP inbound for ${local.worker_name}"

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }

  target_tags   = [local.worker_name]
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_instance" "gcp_worker" {
  name         = local.worker_name
  machine_type = var.worker_machine_type
  zone         = var.worker_zone
  tags         = [local.worker_name]

  boot_disk {
    initialize_params {
      image = "projects/${var.bootstrap_image_project}/global/images/family/${var.bootstrap_image_family}"
      size  = var.worker_disk_size_gb
      type  = var.disk_type
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  shielded_instance_config {
    enable_secure_boot          = false
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  metadata = {
    bootstrap-ssh-public-key = var.bootstrap_ssh_public_key
    serial-port-enable       = "TRUE"
    startup-script           = local.bootstrap_startup_script
  }

  lifecycle {
    ignore_changes = [
      metadata["bootstrap-ssh-public-key"],
      metadata["startup-script"],
      # Power state is managed out of band (on-worker start + the in-guest idle
      # shutdown); never let Terraform fight the start/stop loop.
      desired_status,
      boot_disk[0].initialize_params[0].type,
    ]
  }
}
