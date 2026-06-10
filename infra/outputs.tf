output "instance_external_ip" {
  description = "External IP of the homeserver-gcp instance (ephemeral)"
  value       = google_compute_instance.homeserver_gcp.network_interface[0].access_config[0].nat_ip
}

output "instance_name" {
  value = google_compute_instance.homeserver_gcp.name
}

output "instance_zone" {
  value = var.zone
}

output "builder_external_ip" {
  description = "External IP of the gcp-builder instance (ephemeral; only routable while the VM is running)"
  value       = google_compute_instance.gcp_builder.network_interface[0].access_config[0].nat_ip
}

output "builder_name" {
  value = google_compute_instance.gcp_builder.name
}

output "agent_external_ip" {
  description = "External IP of the gcp-agent instance (ephemeral; only routable while the VM is running)"
  value       = google_compute_instance.gcp_agent.network_interface[0].access_config[0].nat_ip
}

output "agent_name" {
  value = google_compute_instance.gcp_agent.name
}

output "snapshot_policy_name" {
  description = "GCE resource policy attached to the homeserver-gcp boot disk for daily snapshots"
  value       = google_compute_resource_policy.homeserver_boot_daily_snapshots.name
}

output "snapshot_storage_locations" {
  description = "Storage locations used by scheduled GCE boot disk snapshots"
  value       = local.snapshot_storage_locations
}
