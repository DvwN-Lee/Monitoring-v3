# Monitoring Module - Argo CD Application for Loki Stack (GitOps)

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

# Argo CD Application for Loki Stack
resource "kubernetes_manifest" "loki_stack_application" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "loki-stack"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io"
      ]
    }
    spec = {
      project = "default"
      source = {
        chart      = "loki-stack"
        repoURL    = "https://grafana.github.io/helm-charts"
        targetRevision = var.loki_version
        helm = {
          releaseName = "loki"
          values = <<-EOT
            loki:
              enabled: true
              persistence:
                enabled: true
                size: ${var.loki_storage_size}
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
              extraVolumeMounts:
                - name: positions
                  mountPath: /tmp
              extraVolumes:
                - name: positions
                  emptyDir: {}

            grafana:
              enabled: false

            prometheus:
              enabled: false

            serviceMonitor:
              enabled: true
              labels:
                release: prometheus
          EOT
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.namespace
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  }
}

# Loki Datasource ConfigMap for Grafana
resource "kubernetes_config_map" "loki_datasource" {
  metadata {
    name      = "loki-datasource"
    namespace = var.namespace
    labels = {
      grafana_datasource = "1"
    }
  }

  data = {
    "loki-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [
        {
          name      = "Loki"
          type      = "loki"
          access    = "proxy"
          url       = "http://loki.${var.namespace}.svc.cluster.local:3100"
          isDefault = false
          editable  = true
        }
      ]
    })
  }

  depends_on = [kubernetes_manifest.loki_stack_application]
}
