# Argo CD Module - GitOps Continuous Delivery
# Installs Argo CD using Helm Chart

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

variable "namespace" {
  description = "Kubernetes namespace for Argo CD"
  type        = string
  default     = "argocd"
}

variable "chart_version" {
  description = "Argo CD Helm chart version"
  type        = string
  default     = "5.51.6"
}

variable "server_service_type" {
  description = "Service type for Argo CD server (ClusterIP, NodePort, LoadBalancer)"
  type        = string
  default     = "NodePort"
}

variable "server_nodeport" {
  description = "NodePort for Argo CD server (30000-32767)"
  type        = number
  default     = 30080
}

# Argo CD Helm Release
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version
  namespace  = var.namespace

  # Wait for all resources to be ready
  wait          = true
  wait_for_jobs = true
  timeout       = 600

  values = [
    yamlencode({
      global = {
        domain = "argocd.local"
      }

      server = {
        service = {
          type     = var.server_service_type
          nodePort = var.server_service_type == "NodePort" ? var.server_nodeport : null
        }
        extraArgs = [
          "--insecure"
        ]
      }

      controller = {
        resources = {
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
          requests = {
            cpu    = "250m"
            memory = "256Mi"
          }
        }
      }

      repoServer = {
        resources = {
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
          requests = {
            cpu    = "250m"
            memory = "256Mi"
          }
        }
      }

      applicationSet = {
        enabled = true
      }

      notifications = {
        enabled = false
      }

      dex = {
        enabled = false
      }
    })
  ]
}

# Wait for Argo CD server to be ready
resource "null_resource" "wait_for_argocd" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for Argo CD to be ready..."
      kubectl wait --for=condition=available --timeout=300s \
        deployment/argocd-server -n ${var.namespace} \
        --kubeconfig ~/.kube/config-solid-cloud || true
      sleep 10
    EOT
  }
}

output "release_name" {
  description = "Argo CD Helm release name"
  value       = helm_release.argocd.name
}

output "namespace" {
  description = "Argo CD namespace"
  value       = var.namespace
}

output "server_endpoint" {
  description = "Argo CD server endpoint"
  value       = var.server_service_type == "NodePort" ? "http://<node-ip>:${var.server_nodeport}" : "Access via kubectl port-forward"
}
