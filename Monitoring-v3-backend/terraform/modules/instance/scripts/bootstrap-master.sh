#!/bin/bash
set -e

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/k3s-bootstrap.log
}

log "Starting k3s master bootstrap..."

# Variables
K3S_TOKEN="${k3s_token}"
PUBLIC_IP="${public_ip}"
PRIVATE_IP=$(hostname -I | awk '{print $1}')

# Install k3s server
log "Installing k3s server..."
curl -sfL https://get.k3s.io | sh -s - server \
    --token="$K3S_TOKEN" \
    --tls-san="$PUBLIC_IP" \
    --tls-san="$PRIVATE_IP" \
    --write-kubeconfig-mode=644 \
    --disable=traefik

# Wait for k3s to be ready
log "Waiting for k3s to be ready..."
until kubectl get nodes &>/dev/null; do
    log "Waiting for k3s API server..."
    sleep 5
done

log "k3s node ready: $(kubectl get nodes)"

# Wait for core pods
log "Waiting for core system pods..."
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=300s

# Create namespaces
log "Creating namespaces..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace titanium-prod --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD
log "Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
log "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=600s

# Patch ArgoCD server service to NodePort
log "Configuring ArgoCD server as NodePort..."
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort","ports":[{"port":443,"nodePort":30080,"targetPort":8080}]}}'

# Create PostgreSQL secret
log "Creating PostgreSQL secret..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-secret
  namespace: titanium-prod
  labels:
    app: postgresql
    managed_by: bootstrap
type: Opaque
data:
  POSTGRES_DB: $(echo -n "titanium" | base64)
  POSTGRES_USER: $(echo -n "postgres" | base64)
  POSTGRES_PASSWORD: $(echo -n "${postgres_password}" | base64)
EOF

# Create ArgoCD Application for titanium-prod
log "Creating ArgoCD Application for titanium-prod..."
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: titanium-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/DvwN-Lee/Monitoring-v2.git
    targetRevision: main
    path: k8s-manifests/overlays/solid-cloud
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
EOF

# Create ArgoCD Application for Loki Stack
log "Creating ArgoCD Application for loki-stack..."
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki-stack
  namespace: argocd
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
                    replacement: /var/log/pods/*\$1/*.log
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

log "Bootstrap complete! ArgoCD applications created."
log "ArgoCD will now sync applications from Git repository."
log "Access ArgoCD UI at: https://$PUBLIC_IP:30080"
log "Get admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
