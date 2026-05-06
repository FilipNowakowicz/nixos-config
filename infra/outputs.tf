output "instance_external_ip" {
  description = "External IP of the homeserver-gcp instance (ephemeral)"
  value       = google_compute_instance.homeserver_gcp.network_interface[0].access_config[0].nat_ip
}

output "instance_name" {
  value = google_compute_instance.homeserver_gcp.name
}

output "ssh_host_key_removal_cmd" {
  description = "Run this after first successful Tailscale join to remove bootstrap metadata"
  value       = "gcloud compute instances remove-metadata ${google_compute_instance.homeserver_gcp.name} --zone=${var.zone} --keys=ssh-host-key-b64,bootstrap-ssh-public-key,startup-script"
}
