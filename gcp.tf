# ==========================================
# 1. PARAMETERS / VARIABLES SECTION
# Change these values per client
# ==========================================

variable "project_id" {
  type        = string
  description = "The Google Cloud Project ID where resources will be deployed."
  default     = "your-gcp-project-id"
}

variable "region" {
  type        = string
  description = "The primary region for the subnets and NAT gateway."
  default     = "us-central1"
}

variable "client_prefix" {
  type        = string
  description = "A naming prefix used to isolate resources per client."
  default     = "finalis-ai"
}

variable "vm_subnet_cidr" {
  type        = string
  description = "The internal IP range for your core VM subnet."
  default     = "10.0.0.0/24"
}

# ==========================================
# 2. PROVIDER CONFIGURATION
# ==========================================

provider "google" {
  project = var.project_id
  region  = var.region
}

# ==========================================
# 3. NETWORKING (Phase 1)
# ==========================================

# Custom VPC Network (Default network excluded)
resource "google_compute_network" "custom_vpc" {
  name                    = "${var.client_prefix}-vpc"
  auto_create_subnetworks = false
}

# Subnet with Private Google Access & Flow Logs Enabled
resource "google_compute_subnetwork" "secure_subnet" {
  name                     = "${var.client_prefix}-subnet-1"
  region                   = var.region
  network                  = google_compute_network.custom_vpc.id
  ip_cidr_range            = var.vm_subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_15_MIN" # Optimizes logging volume/costs
    flow_sampling        = 0.5                # Logs 50% of packets
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Cloud Router (Prerequisite for Cloud NAT)
resource "google_compute_router" "nat_router" {
  name    = "${var.client_prefix}-router"
  region  = var.region
  network = google_compute_network.custom_vpc.id
}

# Public Cloud NAT Gateway (For secure outbound internet)
resource "google_compute_router_nat" "public_nat" {
  name                               = "${var.client_prefix}-gateway"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Secure Inbound Firewall Rule: Allows SSH *only* via Identity-Aware Proxy (IAP)
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.client_prefix}-allow-iap-ssh"
  network = google_compute_network.custom_vpc.name

  direction = "INGRESS"
  priority  = 1000

  # Google's official hardcoded secure IAP IP range
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  target_tags = ["secure-ssh"]
}

# ==========================================
# 4. IDENTITY & ACCESS MANAGEMENT (Phase 2)
# ==========================================

# Workload-Specific Service Account
resource "google_service_account" "workload_sa" {
  account_id   = "${var.client_prefix}-sa"
  display_name = "Workload Service Account for ${var.client_prefix} application instances"
}

# IAM Role: Secret Manager Accessor
resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.workload_sa.email}"
}

# IAM Role: Vertex AI / Gemini Agent Platform User (For Vector Search migration)
resource "google_project_iam_member" "vertex_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.workload_sa.email}"
}

# ==========================================
# 5. PROJECT-WIDE SECURITY SETTINGS (Phase 3)
# ==========================================

# Enforce OS Login across the project
resource "google_compute_project_metadata_item" "enable_os_login" {
  key   = "enable-oslogin"
  value = "TRUE"
}

# Block legacy project-wide SSH keys
resource "google_compute_project_metadata_item" "block_project_ssh" {
  key   = "block-project-ssh-keys"
  value = "TRUE"
}

# ==========================================
# 6. PRIVATE SERVICES ACCESS (Phase 5)
# ==========================================

# Automatically allocate an unused internal IP range for managed services (Cloud SQL/Vector DB)
resource "google_compute_global_address" "psa_ip_range" {
  name          = "${var.client_prefix}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24 # Grants a /24 block automatically tailored to not conflict
  network       = google_compute_network.custom_vpc.id
}

# Establish the private VPC Peering connection to Google Service Networking
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.custom_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_ip_range.name]
}