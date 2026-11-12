# INTENTIONAL WEAKNESSES on this VM, each required by the exercise:
#   - Ubuntu 20.04 (released April 2020, well over a year old)
#   - MongoDB 4.4 (EOL February 2024), installed by the startup script
#   - SSH open to 0.0.0.0/0 (network.tf)
#   - Over-permissive service account: roles/compute.admin + roles/storage.admin on the project

resource "google_service_account" "mongo" {
  account_id   = "mongo-vm"
  display_name = "Mongo VM identity (intentionally over-permissive)"
}

resource "google_project_iam_member" "mongo_overprivileged" {
  for_each = toset(["roles/compute.admin", "roles/storage.admin"])
  project  = var.project
  role     = each.value
  member   = "serviceAccount:${google_service_account.mongo.email}"
}

# Not part of the weakness: the Ops Agent needs these to ship auth.log (the SSH-login detection's data source)
# and VM metrics. Without logWriter every write is refused and the ssh-login-mongo-vm alert never sees data.
resource "google_project_iam_member" "mongo_agent" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter"])
  project  = var.project
  role     = each.value
  member   = "serviceAccount:${google_service_account.mongo.email}"
}

resource "random_password" "mongo_admin" {
  length  = 24
  special = false
}

resource "random_password" "mongo_app" {
  length  = 24
  special = false
}

# The app's connection string lives in Secret Manager; the app pipeline copies it into a Kubernetes Secret.
resource "google_secret_manager_secret" "mongodb_uri" {
  secret_id = "mongodb-uri"
  labels    = local.labels
  # User-managed in one region: the lab org's gcp.resourceLocations policy refuses "global" (automatic) replication.
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "mongodb_uri" {
  secret      = google_secret_manager_secret.mongodb_uri.id
  secret_data = "mongodb://tasky:${random_password.mongo_app.result}@${google_compute_instance.mongo.network_interface[0].network_ip}:27017/todo?authSource=todo"
}

resource "google_compute_instance" "mongo" {
  name         = "mongo-vm"
  machine_type = var.mongo_machine_type
  zone         = var.zone
  tags         = ["mongo"]
  labels       = local.labels

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-focal-v20250606" # outdated on purpose
      size  = 20
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.public.id
    access_config {} # public IP: required for the "SSH exposed to the internet" weakness
  }

  service_account {
    email  = google_service_account.mongo.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "FALSE" # classic ssh keys in metadata; leaves the broader attack surface the exercise wants
  }

  metadata_startup_script = templatefile("${path.module}/scripts/mongo-startup.sh", {
    admin_password = random_password.mongo_admin.result
    app_password   = random_password.mongo_app.result
    backup_bucket  = google_storage_bucket.backups.name
  })

  depends_on = [google_project_service.apis]
}
