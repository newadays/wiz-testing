# Workload Identity Federation: GitHub Actions authenticates with a short-lived OIDC token. No JSON keys anywhere.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"
  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }
  attribute_condition = "assertion.repository == '${var.github_repo}'"
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Two identities, one per pipeline, each with only what that pipeline needs.
resource "google_service_account" "iac" {
  account_id   = "ci-iac"
  display_name = "IaC pipeline (terraform plan/apply)"
}

resource "google_service_account" "app" {
  account_id   = "ci-app"
  display_name = "App pipeline (build, push, deploy)"
}

# The IaC pipeline creates every resource above, so it is broad by nature; scope it to this project only.
resource "google_project_iam_member" "iac" {
  for_each = toset([
    "roles/compute.admin", "roles/container.admin", "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser", "roles/resourcemanager.projectIamAdmin", "roles/storage.admin",
    "roles/secretmanager.admin", "roles/logging.admin", "roles/monitoring.admin",
    "roles/artifactregistry.admin", "roles/gkehub.admin", "roles/serviceusage.serviceUsageAdmin",
    "roles/iam.workloadIdentityPoolAdmin",
  ])
  project = var.project
  role    = each.value
  member  = "serviceAccount:${google_service_account.iac.email}"
}

resource "google_project_iam_member" "app" {
  for_each = toset([
    "roles/artifactregistry.writer", # push images
    "roles/gkehub.gatewayEditor",    # kubectl through the Connect gateway
    "roles/gkehub.viewer",
    "roles/container.clusterViewer",
  ])
  project = var.project
  role    = each.value
  member  = "serviceAccount:${google_service_account.app.email}"
}

resource "google_secret_manager_secret_iam_member" "app_reads_uri" {
  secret_id = google_secret_manager_secret.mongodb_uri.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app.email}"
}

resource "google_service_account_iam_member" "iac_wif" {
  service_account_id = google_service_account.iac.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

resource "google_service_account_iam_member" "app_wif" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}
