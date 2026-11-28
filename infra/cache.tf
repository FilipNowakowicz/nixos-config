# ── Fleet binary cache storage (#631) ────────────────────────────────────────
#
# atticd on homeserver-gcp keeps its chunks here through GCS's S3-compatible
# XML API (hosts/homeserver-gcp/attic.nix). The cache is rebuildable: attic's
# retention period and garbage collector bound it, so this bucket has no
# versioning, no soft delete and no object-age deletion of its own. Deleting
# objects behind attic's back would leave its database pointing at missing
# chunks, so the only lifecycle rule here cleans up abandoned multipart uploads.
#
# Same region as both VMs, so the builder's pushes and the homeserver's reads
# stay inside europe-west2.
#
# The HMAC key for the account below is created outside Terraform, like the CI
# builder key in builder.tf, so its secret never enters state. Create or rotate
# it with the commands in hosts/homeserver-gcp/CLAUDE.md ("Binary cache").
#
# NOTE: apply manually:
#   cd infra && tofu plan && tofu apply

resource "google_storage_bucket" "attic" {
  name     = "nixos-config-attic-8c41e7"
  location = var.region

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # attic deletes chunks itself; a deleted object kept for soft-delete days
  # would only add cost.
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  lifecycle_rule {
    condition {
      age = 1
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  labels = {
    purpose = "nix-binary-cache"
    host    = local.name
  }
}

resource "google_service_account" "attic" {
  account_id   = "attic-cache"
  display_name = "attic: fleet binary cache storage"
}

# Object read/write/delete on this one bucket and nothing else in the project.
resource "google_storage_bucket_iam_member" "attic" {
  bucket = google_storage_bucket.attic.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.attic.email}"
}
