terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # The bucket is created outside this configuration so `tofu destroy` cannot
  # reach the state it is using. See "Terraform State" in docs/operations.md.
  backend "gcs" {
    bucket = "nixos-config-tfstate-8c41e7"
    prefix = "terraform/state"
  }
}

provider "google" {
  project = var.gcp_project
  region  = var.region
}
