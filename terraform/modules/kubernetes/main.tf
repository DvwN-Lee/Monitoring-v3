# Kubernetes Cluster Module
# This module manages Kubernetes cluster and namespaces

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "node_count" {
  description = "Number of nodes in the cluster"
  type        = number
  default     = 3
}

variable "node_instance_type" {
  description = "Instance type for nodes"
  type        = string
  default     = "t3.medium"
}

# Kubernetes Namespaces
resource "kubernetes_namespace" "titanium_prod" {
  metadata {
    name = "titanium-prod"
    labels = {
      name        = "titanium-prod"
      environment = "production"
      managed_by  = "terraform"
    }
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      name       = "monitoring"
      managed_by = "terraform"
    }
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      name       = "argocd"
      managed_by = "terraform"
    }
  }
}

# Resource Quota for titanium-prod namespace
resource "kubernetes_resource_quota" "titanium_prod" {
  metadata {
    name      = "titanium-prod-quota"
    namespace = kubernetes_namespace.titanium_prod.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = "8"
      "requests.memory" = "16Gi"
      "limits.cpu"      = "16"
      "limits.memory"   = "32Gi"
      "pods"            = "50"
    }
  }
}

# Application Secrets
resource "kubernetes_secret" "app_secrets" {
  metadata {
    name      = "prod-app-secrets"
    namespace = kubernetes_namespace.titanium_prod.metadata[0].name
    labels = {
      app        = "titanium"
      managed_by = "terraform"
    }
  }

  data = {
    POSTGRES_USER       = "postgres"
    POSTGRES_PASSWORD   = var.postgres_password
    JWT_SECRET_KEY      = var.jwt_secret_key
    INTERNAL_API_SECRET = var.internal_api_secret
    REDIS_PASSWORD      = var.redis_password
  }

  type = "Opaque"
}

# Cluster outputs
output "cluster_endpoint" {
  description = "Kubernetes cluster endpoint"
  value       = "https://solid-cloud-k8s-endpoint" # Replace with actual endpoint
}

output "namespaces" {
  description = "Created namespaces"
  value = {
    titanium_prod = kubernetes_namespace.titanium_prod.metadata[0].name
    monitoring    = kubernetes_namespace.monitoring.metadata[0].name
    argocd        = kubernetes_namespace.argocd.metadata[0].name
  }
}
