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

# The VM moves between zones when one runs out of capacity (scripts/lib/builder.sh),
# so Terraform cannot track it. Its definition is in git history for a full
# reprovision. See hosts/gcp-builder/CLAUDE.md.
removed {
  from = google_compute_instance.gcp_builder
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_compute_instance_iam_member.ci_builder_start
  lifecycle {
    destroy = false
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

locals {
  # IAM conditions allow at most 12 logical operators, so zonal resources match
  # by region and name rather than by listing every zone.
  ci_builder_zonal_suffixes = [
    "/instances/${local.builder_name}",
    "/instances/${local.builder_name}-probe",
    "/disks/${local.builder_name}",
    "/disks/${local.builder_name}-probe",
  ]
  ci_builder_shared_resources = [
    "projects/${var.gcp_project}/global/snapshots/${local.builder_name}-move",
    "projects/${var.gcp_project}/global/networks/default",
    "projects/${var.gcp_project}/regions/${var.region}/subnetworks/default",
    "projects/${var.gcp_project}/regions/${var.region}/resourcePolicies/${google_compute_resource_policy.builder_weekly_prebuild.name}",
  ]
  ci_builder_condition = join(" || ", concat(
    ["(resource.name.startsWith('projects/${var.gcp_project}/zones/${var.region}-') && (${join(" || ", [for suffix in local.ci_builder_zonal_suffixes : "resource.name.endsWith('${suffix}')"])}))"],
    [for name in local.ci_builder_shared_resources : "resource.name == '${name}'"],
  ))
}

# Everything CI needs to start the builder or move it to another zone. Bound
# only to the resources above, so this account cannot touch any other VM.
resource "google_project_iam_custom_role" "ci_builder_move" {
  role_id = "ciBuilderMove"
  title   = "CI: start and move gcp-builder"
  permissions = [
    "compute.disks.create",
    "compute.disks.createSnapshot",
    "compute.disks.delete",
    "compute.disks.get",
    "compute.disks.use",
    "compute.disks.useReadOnly",
    "compute.instances.create",
    "compute.instances.delete",
    "compute.instances.get",
    "compute.instances.setMetadata",
    "compute.instances.setTags",
    "compute.instances.start",
    "compute.instances.addResourcePolicies",
    "compute.instances.updateShieldedInstanceConfig",
    "compute.networks.use",
    "compute.networks.useExternalIp",
    "compute.resourcePolicies.use",
    "compute.snapshots.create",
    "compute.snapshots.delete",
    "compute.snapshots.get",
    "compute.snapshots.setLabels",
    "compute.snapshots.useReadOnly",
    "compute.subnetworks.use",
    "compute.subnetworks.useExternalIp",
  ]
}

resource "google_project_iam_member" "ci_builder_move" {
  project = var.gcp_project
  role    = google_project_iam_custom_role.ci_builder_move.id
  member  = "serviceAccount:${google_service_account.ci_builder_start.email}"
  condition {
    title      = "gcp-builder resources only"
    expression = local.ci_builder_condition
  }
}

# Polling a long-running operation has no named resource to condition on.
resource "google_project_iam_custom_role" "ci_builder_operations" {
  role_id = "ciBuilderOperations"
  title   = "CI: follow compute operations"
  permissions = [
    "compute.globalOperations.get",
    "compute.regionOperations.get",
    "compute.zoneOperations.get",
  ]
}

resource "google_project_iam_member" "ci_builder_operations" {
  project = var.gcp_project
  role    = google_project_iam_custom_role.ci_builder_operations.id
  member  = "serviceAccount:${google_service_account.ci_builder_start.email}"
}
