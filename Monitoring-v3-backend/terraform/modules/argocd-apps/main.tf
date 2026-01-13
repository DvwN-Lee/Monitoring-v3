# Argo CD Applications Module - kubectl 기반
# YAML 매니페스트를 Terraform 코드에 임베드하여 외부 파일 의존성 제거

terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

variable "argocd_namespace" {
  description = "Argo CD namespace"
  type        = string
  default     = "argocd"
}

variable "git_repo_url" {
  description = "Git repository URL"
  type        = string
  default     = "https://github.com/DvwN-Lee/Monitoring-v3.git"
}

variable "git_revision" {
  description = "Git branch/tag to track"
  type        = string
  default     = "main"
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config-gcp"
}

variable "depends_on_resources" {
  description = "Resources this module depends on"
  type        = any
  default     = []
}

# Titanium Production Application
resource "null_resource" "titanium_prod_app" {
  depends_on = [var.depends_on_resources]

  provisioner "local-exec" {
    command = <<-EOT
      cat <<'EOF' | KUBECONFIG=${var.kubeconfig_path} kubectl apply -f -
      apiVersion: argoproj.io/v1alpha1
      kind: Application
      metadata:
        name: titanium-prod
        namespace: ${var.argocd_namespace}
        finalizers:
          - resources-finalizer.argocd.argoproj.io
      spec:
        project: default
        source:
          repoURL: ${var.git_repo_url}
          targetRevision: ${var.git_revision}
          path: k8s-manifests/overlays/gcp
        destination:
          server: https://kubernetes.default.svc
          namespace: titanium-prod
        syncPolicy:
          automated:
            prune: true
            selfHeal: true
            allowEmpty: false
          syncOptions:
            - CreateNamespace=true
            - PruneLast=true
            - Validate=true
            - ServerSideApply=true
          retry:
            limit: 5
            backoff:
              duration: 5s
              factor: 2
              maxDuration: 3m
        ignoreDifferences:
          - group: ""
            kind: Secret
            jsonPointers:
              - /data
          - group: ""
            kind: ConfigMap
            name: prod-app-config
            jsonPointers:
              - /metadata/annotations
      EOF

      echo "Titanium Production Application created successfully"
    EOT
  }

  # Cleanup on destroy
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      KUBECONFIG=${self.triggers.kubeconfig_path} kubectl delete application titanium-prod \
        -n ${self.triggers.argocd_namespace} --ignore-not-found=true || true
    EOT
  }

  triggers = {
    git_repo_url    = var.git_repo_url
    git_revision    = var.git_revision
    kubeconfig_path = var.kubeconfig_path
    argocd_namespace = var.argocd_namespace
  }
}

# Loki Stack Monitoring Application
resource "null_resource" "loki_stack_app" {
  depends_on = [var.depends_on_resources]

  provisioner "local-exec" {
    command = <<-EOT
      cat <<'EOF' | KUBECONFIG=${var.kubeconfig_path} kubectl apply -f -
      apiVersion: argoproj.io/v1alpha1
      kind: Application
      metadata:
        name: loki-stack
        namespace: ${var.argocd_namespace}
        finalizers:
          - resources-finalizer.argocd.argoproj.io
      spec:
        project: default
        source:
          chart: loki-stack
          repoURL: https://grafana.github.io/helm-charts
          targetRevision: 2.10.2
          helm:
            releaseName: loki
            values: |
              loki:
                enabled: true
                persistence:
                  enabled: true
                  size: 10Gi
                config:
                  auth_enabled: false
                  ingester:
                    chunk_idle_period: 3m
                    chunk_block_size: 262144
                    chunk_retain_period: 1m
                    max_transfer_retries: 0
                    lifecycler:
                      ring:
                        kvstore:
                          store: inmemory
                        replication_factor: 1
                  limits_config:
                    enforce_metric_name: false
                    reject_old_samples: true
                    reject_old_samples_max_age: 168h
                    ingestion_rate_mb: 10
                    ingestion_burst_size_mb: 20
                  schema_config:
                    configs:
                    - from: 2020-10-24
                      store: boltdb-shipper
                      object_store: filesystem
                      schema: v11
                      index:
                        prefix: index_
                        period: 24h
                  server:
                    http_listen_port: 3100
                  storage_config:
                    boltdb_shipper:
                      active_index_directory: /data/loki/boltdb-shipper-active
                      cache_location: /data/loki/boltdb-shipper-cache
                      cache_ttl: 24h
                      shared_store: filesystem
                    filesystem:
                      directory: /data/loki/chunks
                  chunk_store_config:
                    max_look_back_period: 168h
                  table_manager:
                    retention_deletes_enabled: true
                    retention_period: 168h
                service:
                  type: ClusterIP
                  port: 3100

              promtail:
                enabled: true
                config:
                  server:
                    http_listen_port: 9080
                    grpc_listen_port: 0
                  positions:
                    filename: /tmp/positions.yaml
                  clients:
                    - url: http://loki:3100/loki/api/v1/push
                  scrape_configs:
                    - job_name: kubernetes-pods
                      kubernetes_sd_configs:
                        - role: pod
                      relabel_configs:
                        - source_labels: [__meta_kubernetes_namespace]
                          regex: (titanium-prod|monitoring)
                          action: keep
                        - source_labels: [__meta_kubernetes_namespace]
                          target_label: namespace
                        - source_labels: [__meta_kubernetes_pod_name]
                          target_label: pod
                        - source_labels: [__meta_kubernetes_pod_container_name]
                          target_label: container
                        - source_labels: [__meta_kubernetes_pod_label_app]
                          target_label: app
                        - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_pod_label_app]
                          separator: /
                          target_label: job
                        - source_labels: [__meta_kubernetes_pod_uid, __meta_kubernetes_pod_container_name]
                          target_label: __path__
                          separator: /
                          replacement: /var/log/pods/*$1/*.log
                      pipeline_stages:
                        - cri: {}
                        - json:
                            expressions:
                              level: level
                              msg: message
                              timestamp: timestamp
                        - labels:
                            level:
                        - timestamp:
                            source: timestamp
                            format: RFC3339Nano
                resources:
                  limits:
                    cpu: 200m
                    memory: 256Mi
                  requests:
                    cpu: 100m
                    memory: 128Mi
                tolerations:
                  - effect: NoSchedule
                    operator: Exists

              grafana:
                enabled: false

              prometheus:
                enabled: false

              serviceMonitor:
                enabled: true
                labels:
                  release: prometheus
        destination:
          server: https://kubernetes.default.svc
          namespace: monitoring
        syncPolicy:
          automated:
            prune: true
            selfHeal: true
          syncOptions:
            - CreateNamespace=true
      EOF

      echo "Loki Stack Application created successfully"
    EOT
  }

  # Cleanup on destroy
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      KUBECONFIG=${self.triggers.kubeconfig_path} kubectl delete application loki-stack \
        -n ${self.triggers.argocd_namespace} --ignore-not-found=true || true
    EOT
  }

  triggers = {
    chart_version    = "2.10.2"
    kubeconfig_path  = var.kubeconfig_path
    argocd_namespace = var.argocd_namespace
  }
}

output "titanium_app_name" {
  description = "Titanium production application name"
  value       = "titanium-prod"
}

output "loki_app_name" {
  description = "Loki stack application name"
  value       = "loki-stack"
}
