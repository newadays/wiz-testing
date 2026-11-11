# Requirement: Kubernetes cluster in a private subnet. Nodes have no external IPs; egress goes through Cloud NAT.
resource "google_service_account" "nodes" {
  account_id   = "gke-nodes"
  display_name = "GKE node identity (least privilege)"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter", "roles/artifactregistry.reader"])
  project  = var.project
  role     = each.value
  member   = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "wiz" {
  name     = "wiz-gke"
  location = var.zone # zonal keeps the lab cheap; regional for real HA

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.private.id

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }
  datapath_provider = "ADVANCED_DATAPATH" # Dataplane V2: NetworkPolicy enforced natively

  # Pod-to-pod traffic on the same node goes through the VPC, so it appears in flow logs. (CKV_GCP_61)
  enable_intranode_visibility = true

  # No client certificates: long-lived credentials that can't be revoked. Access is through IAM only. (CKV_GCP_13)
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # kubectl from the laptop only. CI reaches the API through the Connect gateway (fleet membership below).
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.operator_cidr
      display_name = "operator"
    }
  }

  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  # Control plane audit logs (Kubernetes API server audit) are always on in GKE and land in Cloud Logging
  # as "k8s.io" audit log entries. Enabling WORKLOADS here also captures container stdout/stderr.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS", "APISERVER"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus { enabled = true }
  }

  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_BASIC" # GKE scans running workloads for CVEs (detective)
  }

  resource_labels = local.labels
  depends_on      = [google_project_service.apis]
}

resource "google_container_node_pool" "general" {
  name       = "general"
  cluster    = google_container_cluster.wiz.id
  node_count = 2

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = "e2-medium"
    disk_size_gb    = 50
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = local.labels
    tags            = ["gke-node"]
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
    workload_metadata_config {
      mode = "GKE_METADATA" # pods cannot read the node's service-account token
    }
  }
}

# Fleet membership so CI can reach the private control plane through the Connect gateway without opening
# master authorized networks to the internet.
resource "google_gke_hub_membership" "wiz" {
  membership_id = "wiz-gke"
  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${google_container_cluster.wiz.id}"
    }
  }
  depends_on = [google_project_service.apis]
}
