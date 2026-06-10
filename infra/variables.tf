variable "gcp_project" {
  type        = string
  description = "GCP project ID (find in GCP console or: gcloud config get-value project)"
}

variable "region" {
  type        = string
  description = "GCP region"
  default     = "europe-west2"
}

variable "zone" {
  type        = string
  description = "GCP zone within the region"
  default     = "europe-west2-a"
}

variable "machine_type" {
  type        = string
  description = "GCE machine type (e2-medium = 2 vCPU, 4 GB RAM; sufficient for full LGTM stack)"
  default     = "e2-medium"
}

variable "disk_size_gb" {
  type        = number
  description = "Boot disk size in GB"
  default     = 50
}

variable "disk_type" {
  type        = string
  description = <<-EOT
    Boot disk type. pd-balanced is the cost-effective default for this workload
    (none of the services are IOPS-bound); pd-ssd is ~70% pricier for no
    meaningful gain here.

    NOTE: GCE cannot change a disk's type in place, so changing this only takes
    effect on freshly provisioned instances. The live instance's type is pinned
    via lifecycle.ignore_changes in main.tf so applying this does not force a
    destructive replacement.
  EOT
  default     = "pd-balanced"
}

variable "builder_machine_type" {
  type        = string
  description = <<-EOT
    Machine type for the on-demand Nix remote builder. Must be a family that
    supports nested virtualization (n2/n2d/c3/...) so the box can run the
    KVM-backed nixos test suite; e2 does NOT support nested virt. Default
    n2-standard-4 = 4 vCPU / 16 GB (~$0.19/hr while running, ~$0 stopped).
  EOT
  default     = "n2-standard-4"
}

variable "builder_disk_size_gb" {
  type        = number
  description = "Boot disk size in GB for the builder. Nix builds and the test suite are disk-hungry, so this is larger than the homeserver default."
  default     = 100
}

variable "agent_machine_type" {
  type        = string
  description = <<-EOT
    Machine type for the on-demand Claude Code agent host. No nested-virt
    requirement (heavy builds/tests offload to gcp-builder), so the cheaper e2
    family is fine. Default e2-standard-4 = 4 vCPU / 16 GB.
  EOT
  default     = "e2-standard-4"
}

variable "agent_disk_size_gb" {
  type        = number
  description = "Boot disk size in GB for the agent host. Sized for repo clone(s) + nix store + worktrees."
  default     = 100
}

variable "snapshot_retention_days" {
  type        = number
  description = "Number of daily GCE boot disk snapshots to retain for fast provider-local rollback"
  default     = 7
}

variable "snapshot_start_time" {
  type        = string
  description = "UTC start time for the daily GCE boot disk snapshot schedule, formatted as HH:MM"
  default     = "03:00"
}

variable "snapshot_storage_locations" {
  type        = list(string)
  description = "Regional or multi-regional storage locations for scheduled snapshots; defaults to the VM region when empty"
  default     = []
}

variable "bootstrap_image_project" {
  type        = string
  description = "GCP project containing the stock bootstrap image family"
  default     = "debian-cloud"
}

variable "bootstrap_image_family" {
  type        = string
  description = "GCP image family used for the temporary bootstrap VM"
  default     = "debian-12"
}

variable "bootstrap_ssh_public_key" {
  type        = string
  sensitive   = true
  description = "Public SSH key installed for temporary root bootstrap access"
}
