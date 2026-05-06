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

variable "ssh_host_key_b64" {
  type        = string
  sensitive   = true
  description = "Base64-encoded SSH host private key injected via instance metadata for sops bootstrap"
}
