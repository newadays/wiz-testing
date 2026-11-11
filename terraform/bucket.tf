# INTENTIONAL WEAKNESS: backups readable and listable by anyone on the internet.
resource "google_storage_bucket" "backups" {
  name                        = "${var.project}-${var.candidate_name}-mongo-backups"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "inherited" # must not be "enforced", or the public binding below is refused
  force_destroy               = true
  labels                      = local.labels
  # Keep previous versions, so backups overwritten or deleted through the public exposure can be recovered. (CKV_GCP_78)
  versioning {
    enabled = true
  }
  lifecycle_rule {
    condition { age = 14 }
    action { type = "Delete" }
  }
  # With versioning on, the rule above only makes old backups noncurrent; this one removes them 14 days later.
  lifecycle_rule {
    condition { days_since_noncurrent_time = 14 }
    action { type = "Delete" }
  }
}

# roles/storage.objectViewer grants storage.objects.get AND storage.objects.list: public read and public listing.
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}
