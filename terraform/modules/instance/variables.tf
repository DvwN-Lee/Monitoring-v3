# Instance Module Variables

variable "cluster_name" {
  description = "Name of the k3s cluster"
  type        = string
}

variable "zone" {
  description = "CloudStack zone name"
  type        = string
}

variable "service_offering" {
  description = "CloudStack service offering for instances"
  type        = string
}

variable "template" {
  description = "CloudStack template for instances"
  type        = string
}

variable "network_id" {
  description = "CloudStack network ID"
  type        = string
}

variable "ssh_keypair" {
  description = "CloudStack SSH keypair name"
  type        = string
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
}

# Firewall Configuration
variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to access SSH (port 22)"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Default to open, but should be restricted in production
}

variable "allowed_k8s_cidrs" {
  description = "List of CIDR blocks allowed to access Kubernetes API (port 6443)"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Default to open, but should be restricted in production
}

variable "allowed_http_cidrs" {
  description = "List of CIDR blocks allowed to access HTTP services (port 80)"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # HTTP can be open for public services
}

variable "postgres_password" {
  description = "PostgreSQL root password for titanium database"
  type        = string
  sensitive   = true
}
