# GCP Environment - Complete GitOps Automation
# Terraform manages infrastructure (VPC, VMs)
# k3s + ArgoCD + Applications are bootstrapped via startup script

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

# GCP Provider Configuration
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# VPC Network
resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

# Subnet
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id
}

# Service Account for k3s cluster (minimum privilege)
resource "google_service_account" "k3s_sa" {
  account_id   = "${var.cluster_name}-sa"
  display_name = "Service Account for K3s Cluster"
}

# IAM Role Bindings for logging and monitoring
resource "google_project_iam_member" "sa_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.k3s_sa.email}"
}

resource "google_project_iam_member" "sa_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.k3s_sa.email}"
}

# Firewall Rules - Allow SSH, k8s API, HTTP, Dashboards
resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.cluster_name}-allow-ssh"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAP (Identity-Aware Proxy) range + additional allowed CIDRs
  source_ranges = concat(["35.235.240.0/20"], var.ssh_allowed_cidrs)
  target_tags   = ["k3s-node"]
}

resource "google_compute_firewall" "allow_k8s_api" {
  name    = "${var.cluster_name}-allow-k8s-api"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["k3s-master"]
}

resource "google_compute_firewall" "allow_dashboards" {
  name    = "${var.cluster_name}-allow-dashboards"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "30000-32767"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["k3s-master", "k3s-worker"]
}

# Internal communication between cluster nodes
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.cluster_name}-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr]
}

# Generate random token for k3s cluster
resource "random_password" "k3s_token" {
  length  = 32
  special = false
}

# External IP for master node
resource "google_compute_address" "master_external_ip" {
  name = "${var.cluster_name}-master-ip"
}

# k3s Master Node
resource "google_compute_instance" "k3s_master" {
  name         = "${var.cluster_name}-master"
  machine_type = var.master_machine_type
  zone         = var.zone

  tags = ["k3s-master", "k3s-node"]

  boot_disk {
    initialize_params {
      image = var.os_image
      size  = var.master_disk_size
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id

    access_config {
      nat_ip = google_compute_address.master_external_ip.address
    }
  }

  metadata = {
    ssh-keys = "ubuntu:${file(var.ssh_public_key_path)}"
  }

  metadata_startup_script = templatefile("${path.module}/scripts/k3s-server.sh", {
    k3s_token         = random_password.k3s_token.result
    postgres_password = var.postgres_password
  })

  service_account {
    email  = google_service_account.k3s_sa.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  depends_on = [
    google_service_account.k3s_sa,
    google_project_iam_member.sa_logging,
    google_project_iam_member.sa_monitoring
  ]
}

# k3s Worker Nodes
resource "google_compute_instance" "k3s_worker" {
  count        = var.worker_count
  name         = "${var.cluster_name}-worker-${count.index + 1}"
  machine_type = var.worker_machine_type
  zone         = var.zone

  tags = ["k3s-worker", "k3s-node"]

  boot_disk {
    initialize_params {
      image = var.os_image
      size  = var.worker_disk_size
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id

    # Add ephemeral public IP (NAT 대신 사용)
    access_config {
      # Ephemeral IP will be auto-assigned
    }
  }

  metadata = {
    ssh-keys = "ubuntu:${file(var.ssh_public_key_path)}"
  }

  metadata_startup_script = templatefile("${path.module}/scripts/k3s-agent.sh", {
    master_ip = google_compute_instance.k3s_master.network_interface[0].network_ip
    k3s_token = random_password.k3s_token.result
  })

  service_account {
    email  = google_service_account.k3s_sa.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # Spot (Preemptible) VM configuration
  scheduling {
    preemptible       = var.use_spot_for_workers
    automatic_restart = !var.use_spot_for_workers
  }

  depends_on = [
    google_compute_instance.k3s_master,
    google_service_account.k3s_sa,
    google_project_iam_member.sa_logging,
    google_project_iam_member.sa_monitoring
  ]
}

# Create local kubeconfig template
resource "null_resource" "create_kubeconfig" {
  depends_on = [google_compute_instance.k3s_master]

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ~/.kube
      cat > ~/.kube/config-gcp <<'KUBE'
apiVersion: v1
kind: Config
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: https://${google_compute_address.master_external_ip.address}:6443
  name: gcp-k3s
contexts:
- context:
    cluster: gcp-k3s
    user: gcp-k3s-admin
  name: gcp-k3s
current-context: gcp-k3s
users:
- name: gcp-k3s-admin
  user:
    username: admin
    password: placeholder
KUBE
      echo "Kubeconfig template created at ~/.kube/config-gcp"
      echo "Note: This is a placeholder. Access cluster after k3s bootstrap completes (~5-10 min)"
      echo "To get actual kubeconfig, SSH into master and run: sudo cat /etc/rancher/k3s/k3s.yaml"
    EOT
  }

  triggers = {
    master_ip = google_compute_address.master_external_ip.address
  }
}
