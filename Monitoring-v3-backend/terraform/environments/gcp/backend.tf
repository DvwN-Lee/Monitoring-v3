# Terraform Remote State Backend Configuration
# GCS bucket must be created before running `terraform init -migrate-state`

terraform {
  backend "gcs" {
    bucket = "titanium-terraform-state"
    prefix = "gcp/k3s-cluster"
  }
}
