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
  description = "List of CIDR blocks allowed to access SSH (port 22). Must be explicitly set."
  type        = list(string)

  validation {
    condition     = length(var.allowed_ssh_cidrs) > 0
    error_message = "At least one CIDR block must be specified for SSH access."
  }

  validation {
    condition     = !contains(var.allowed_ssh_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed for SSH access. Specify restricted CIDR blocks."
  }
}

variable "allowed_k8s_cidrs" {
  description = "List of CIDR blocks allowed to access Kubernetes API (port 6443). Must be explicitly set."
  type        = list(string)

  validation {
    condition     = length(var.allowed_k8s_cidrs) > 0
    error_message = "At least one CIDR block must be specified for Kubernetes API access."
  }

  validation {
    condition     = !contains(var.allowed_k8s_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed for Kubernetes API access. Specify restricted CIDR blocks."
  }
}

variable "allowed_http_cidrs" {
  description = "List of CIDR blocks allowed to access HTTP services (port 80)"
  type        = list(string)
  default     = ["0.0.0.0/0"] # HTTP can be open for public services
}

variable "postgres_password" {
  description = "PostgreSQL root password for titanium database"
  type        = string
  sensitive   = true
}
