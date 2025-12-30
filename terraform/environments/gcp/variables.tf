# GCP Environment Variables

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "asia-northeast3"
}

variable "zone" {
  description = "GCP Zone"
  type        = string
  default     = "asia-northeast3-a"
}

variable "cluster_name" {
  description = "Name of the k3s cluster"
  type        = string
  default     = "titanium-k3s"
}

variable "subnet_cidr" {
  description = "CIDR block for the subnet"
  type        = string
  default     = "10.128.0.0/20"
}

variable "master_machine_type" {
  description = "Machine type for master node"
  type        = string
  default     = "e2-medium"
}

variable "worker_machine_type" {
  description = "Machine type for worker nodes"
  type        = string
  default     = "e2-standard-2"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 1
}

variable "use_spot_for_workers" {
  description = "Use Spot (Preemptible) VMs for worker nodes"
  type        = bool
  default     = true
}

variable "master_disk_size" {
  description = "Disk size for master node in GB"
  type        = number
  default     = 30
}

variable "worker_disk_size" {
  description = "Disk size for worker nodes in GB"
  type        = number
  default     = 40
}

variable "os_image" {
  description = "OS image for instances"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2204-lts"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "postgres_password" {
  description = "PostgreSQL root password for titanium database"
  type        = string
  sensitive   = true
}

variable "ssh_allowed_cidrs" {
  description = "Additional CIDR blocks allowed for SSH access (besides IAP)"
  type        = list(string)
  default     = []
}

variable "additional_admin_cidrs" {
  description = "Additional CIDR blocks for Kubernetes API and Dashboard access (current IP is auto-detected)"
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "prod"
}
