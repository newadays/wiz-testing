resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com", "container.googleapis.com", "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com", "iam.googleapis.com", "iamcredentials.googleapis.com",
    "sts.googleapis.com", "logging.googleapis.com", "monitoring.googleapis.com",
    "gkehub.googleapis.com", "connectgateway.googleapis.com", "cloudresourcemanager.googleapis.com",
    "securitycenter.googleapis.com", "orgpolicy.googleapis.com", "osconfig.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}
