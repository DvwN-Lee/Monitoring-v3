# Monitoring Module Variables

variable "namespace" {
  description = "Kubernetes namespace for monitoring stack"
  type        = string
  default     = "monitoring"
}

variable "loki_version" {
  description = "Loki stack Helm chart version"
  type        = string
  default     = "2.10.2"  # Stable version
}

variable "loki_storage_size" {
  description = "Persistent volume size for Loki logs"
  type        = string
  default     = "10Gi"
}

variable "depends_on_resources" {
  description = "Resources that monitoring stack depends on"
  type        = any
  default     = []
}
