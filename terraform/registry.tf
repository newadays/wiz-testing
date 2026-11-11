resource "google_artifact_registry_repository" "apps" {
  location      = var.region
  repository_id = "apps"
  format        = "DOCKER"
  labels        = local.labels
  depends_on    = [google_project_service.apis]
}
