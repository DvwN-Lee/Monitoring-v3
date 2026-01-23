#!/bin/bash
# Terraform Backend Initialization Script
# Automates GCS backend setup and Service Account configuration

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Print functions
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if PROJECT_ID is provided
if [ -z "$1" ]; then
    print_error "Usage: $0 <PROJECT_ID> [SA_KEY_PATH]"
    echo "Example: $0 my-project-id ~/terraform-sa-key.json"
    exit 1
fi

PROJECT_ID=$1
SA_KEY_PATH=${2:-"$HOME/terraform-sa-key.json"}
BUCKET_NAME="${PROJECT_ID}-terraform-state"
SA_NAME="terraform-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

print_info "Starting Terraform initialization for project: ${PROJECT_ID}"

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    print_error "gcloud CLI is not installed. Please install it first."
    exit 1
fi

# Set active project
print_info "Setting active GCP project..."
gcloud config set project ${PROJECT_ID}

# Enable required APIs
print_info "Enabling required GCP APIs..."
gcloud services enable compute.googleapis.com \
    iam.googleapis.com \
    cloudresourcemanager.googleapis.com \
    serviceusage.googleapis.com \
    storage.googleapis.com

print_info "Waiting for APIs to be fully enabled (30 seconds)..."
sleep 30

# Create Service Account if not exists
if gcloud iam service-accounts describe ${SA_EMAIL} --project=${PROJECT_ID} &> /dev/null; then
    print_warn "Service Account ${SA_EMAIL} already exists"
else
    print_info "Creating Service Account: ${SA_NAME}"
    gcloud iam service-accounts create ${SA_NAME} \
        --display-name="Terraform Service Account" \
        --project=${PROJECT_ID}
fi

# Grant necessary roles
print_info "Granting IAM roles to Service Account..."
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/owner" \
    --quiet

# Create Service Account key if not exists
if [ -f "${SA_KEY_PATH}" ]; then
    print_warn "Service Account key already exists at ${SA_KEY_PATH}"
    read -p "Do you want to create a new key? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Creating new Service Account key..."
        mv ${SA_KEY_PATH} ${SA_KEY_PATH}.old
        gcloud iam service-accounts keys create ${SA_KEY_PATH} \
            --iam-account=${SA_EMAIL}
        chmod 600 ${SA_KEY_PATH}
    fi
else
    print_info "Creating Service Account key at ${SA_KEY_PATH}"
    gcloud iam service-accounts keys create ${SA_KEY_PATH} \
        --iam-account=${SA_EMAIL}
    chmod 600 ${SA_KEY_PATH}
fi

# Export credentials
export GOOGLE_APPLICATION_CREDENTIALS=${SA_KEY_PATH}
print_info "GOOGLE_APPLICATION_CREDENTIALS set to ${SA_KEY_PATH}"

# Create GCS bucket for Terraform state if not exists
if gcloud storage buckets describe gs://${BUCKET_NAME} &> /dev/null; then
    print_warn "GCS bucket ${BUCKET_NAME} already exists"
else
    print_info "Creating GCS bucket: ${BUCKET_NAME}"
    gcloud storage buckets create gs://${BUCKET_NAME} \
        --project=${PROJECT_ID} \
        --location=asia-northeast3 \
        --uniform-bucket-level-access

    print_info "Enabling versioning on GCS bucket..."
    gcloud storage buckets update gs://${BUCKET_NAME} --versioning
fi

# Update backend.tf with correct bucket name
BACKEND_FILE="backend.tf"
if [ -f "${BACKEND_FILE}" ]; then
    print_info "Updating backend.tf with bucket name..."
    cat > ${BACKEND_FILE} << EOF
# Terraform Remote State Backend Configuration
# GCS bucket must be created before running \`terraform init -migrate-state\`

terraform {
  backend "gcs" {
    bucket = "${BUCKET_NAME}"
    prefix = "gcp/k3s-cluster"
  }
}
EOF
else
    print_warn "backend.tf not found in current directory"
fi

# Initialize Terraform
print_info "Initializing Terraform..."
if [ -f "terraform.tfstate" ]; then
    print_warn "Local terraform.tfstate found"
    read -p "Do you want to migrate state to GCS? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cp terraform.tfstate terraform.tfstate.backup
        rm -rf .terraform
        terraform init -migrate-state
    else
        rm -rf .terraform
        terraform init -reconfigure
    fi
else
    rm -rf .terraform
    terraform init
fi

print_info "Terraform initialization completed successfully!"
echo
print_info "Environment variables to add to your shell profile:"
echo "export GOOGLE_APPLICATION_CREDENTIALS=${SA_KEY_PATH}"
echo
print_info "Next steps:"
echo "1. Update terraform.tfvars with your project_id: ${PROJECT_ID}"
echo "2. Run: terraform plan -var-file=\"secrets.tfvars\""
echo "3. Run: terraform apply -var-file=\"secrets.tfvars\""
