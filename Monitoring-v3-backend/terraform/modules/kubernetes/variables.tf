# Kubernetes Module Variables
# Note: cluster_name, node_count, node_instance_type는 main.tf에 정의됨

# Secret Management Variables
variable "postgres_password" {
  description = "PostgreSQL password for app-secrets"
  type        = string
  sensitive   = true
}

variable "jwt_secret_key" {
  description = "JWT secret key for authentication"
  type        = string
  sensitive   = true
  default     = "jwt-signing-key"
}

variable "internal_api_secret" {
  description = "Internal API secret for service communication"
  type        = string
  sensitive   = true
  default     = "api-secret-key"
}

variable "redis_password" {
  description = "Redis password"
  type        = string
  sensitive   = true
  default     = "redis-password"
}
