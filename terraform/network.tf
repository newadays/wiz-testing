# One VPC, two subnets: public (Mongo VM, external IP) and private (GKE nodes, no external IPs).
resource "google_compute_network" "vpc" {
  name                    = "wiz-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "public" {
  name          = "public-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.0.1.0/24"
  # Reach Google APIs (e.g. the backup bucket) over Google's network, not the public internet. (CKV_GCP_74)
  private_ip_google_access = true
  # Flow logs on the subnet with the exposed VM: a record of every connection to public SSH and Mongo. (CKV_GCP_26)
  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "private" {
  name                     = "private-subnet"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.0.2.0/24"
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.10.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.20.0.0/20"
  }
  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Private nodes need NAT to pull images and reach apt/pip.
resource "google_compute_router" "router" {
  name    = "wiz-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "wiz-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# INTENTIONAL WEAKNESS: SSH open to the internet on the Mongo VM.
resource "google_compute_firewall" "mongo_ssh_public" {
  name          = "mongo-allow-ssh-public"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["mongo"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Requirement: MongoDB reachable only from the Kubernetes network (nodes subnet + pod range).
resource "google_compute_firewall" "mongo_from_gke" {
  name          = "mongo-allow-from-gke"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = [google_compute_subnetwork.private.ip_cidr_range, "10.10.0.0/16"]
  target_tags   = ["mongo"]
  allow {
    protocol = "tcp"
    ports    = ["27017"]
  }
}

# Google load balancer and health-check ranges to the GKE pods (container-native LB uses pod IPs directly).
resource "google_compute_firewall" "allow_lb_health" {
  name          = "gke-allow-lb-health"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}
