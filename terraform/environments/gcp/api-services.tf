# GCP API Services Enablement
# Automatically enables required APIs for K3s cluster deployment

# Compute Engine API - Required for VM instances, networks, and firewall rules
resource "google_project_service" "compute" {
  project = var.project_id
  service = "compute.googleapis.com"

  disable_on_destroy = false
}

# IAM API - Required for Service Account creation and management
resource "google_project_service" "iam" {
  project = var.project_id
  service = "iam.googleapis.com"

  disable_on_destroy = false
}

# Cloud Resource Manager API - Required for project-level operations
resource "google_project_service" "cloudresourcemanager" {
  project = var.project_id
  service = "cloudresourcemanager.googleapis.com"

  disable_on_destroy = false
}

# Service Usage API - Required for enabling other APIs
resource "google_project_service" "serviceusage" {
  project = var.project_id
  service = "serviceusage.googleapis.com"

  disable_on_destroy = false
}

# Ensure APIs are enabled before creating other resources
# This prevents "API not enabled" errors during deployment
