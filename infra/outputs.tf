output "instance_external_ip" {
  description = "External IP of the homeserver-gcp instance (ephemeral)"
  value       = google_compute_instance.homeserver_gcp.network_interface[0].access_config[0].nat_ip
}

output "instance_name" {
  value = google_compute_instance.homeserver_gcp.name
}

output "instance_zone" {
  value = google_compute_instance.homeserver_gcp.zone
}

output "snapshot_policy_name" {
  description = "GCE resource policy attached to the homeserver-gcp boot disk for daily snapshots"
  value       = google_compute_resource_policy.homeserver_boot_daily_snapshots.name
}

output "snapshot_storage_locations" {
  description = "Storage locations used by scheduled GCE boot disk snapshots"
  value       = local.snapshot_storage_locations
}

output "attic_bucket" {
  description = "GCS bucket holding the attic binary cache chunks"
  value       = google_storage_bucket.attic.name
}

output "attic_service_account" {
  description = "Service account whose HMAC key atticd uses for the cache bucket"
  value       = google_service_account.attic.email
}
