#!/bin/bash
set -e

# Complete K3s + ArgoCD + GitOps Bootstrap Script for GCP
# This script runs on the master node via startup script and sets up the entire stack

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/k3s-bootstrap.log
}

log "Starting complete k3s + ArgoCD bootstrap..."

# Variables
K3S_TOKEN="${k3s_token}"
POSTGRES_PASSWORD="${postgres_password}"
PRIVATE_IP=$(hostname -I | awk '{print $1}')

# Wait for metadata service and get public IP
log "Retrieving public IP from metadata..."
for i in {1..30}; do
  PUBLIC_IP=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip 2>/dev/null || echo "")
  if [ -n "$PUBLIC_IP" ]; then
    log "Public IP: $PUBLIC_IP"
    break
  fi
  log "Waiting for metadata service... attempt $i/30"
  sleep 2
done

# Install k3s server
if [ -n "$PUBLIC_IP" ]; then
  log "Installing k3s with TLS SAN for $PRIVATE_IP and $PUBLIC_IP"
  curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
    --write-kubeconfig-mode 644 \
    --disable traefik \
    --tls-san "$PRIVATE_IP" \
    --tls-san "$PUBLIC_IP"
else
  log "Installing k3s with private IP only"
  curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
    --write-kubeconfig-mode 644 \
    --disable traefik \
    --tls-san "$PRIVATE_IP"
fi

# Setup kubectl for root and ubuntu users
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config

# Wait for k3s to be ready
log "Waiting for k3s API server..."
until kubectl get nodes &>/dev/null; do
    log "Waiting for k3s API server..."
    sleep 5
done

log "k3s node ready: $(kubectl get nodes)"

# Wait for core system pods
log "Waiting for core system pods..."
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=300s || log "Warning: Some system pods not ready"

# Create namespaces
log "Creating namespaces..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace titanium-prod --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD
log "Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
log "Waiting for ArgoCD deployments..."
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=600s || log "Warning: ArgoCD may not be fully ready"

# Patch ArgoCD server to NodePort 30080
log "Configuring ArgoCD server as NodePort:30080..."
kubectl patch svc argocd-server -n argocd --type='json' -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"add","path":"/spec/ports/0/nodePort","value":30080}]'

# Make ArgoCD server insecure (no TLS) for easier access
kubectl patch deployment argocd-server -n argocd --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

# Create PostgreSQL secret for titanium-prod
log "Creating PostgreSQL secret..."
kubectl create secret generic postgresql-secret \
  --from-literal=POSTGRES_DB=titanium \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --namespace=titanium-prod \
  --dry-run=client -o yaml | kubectl apply -f -

# Create ArgoCD Application for titanium-prod
log "Creating ArgoCD Application for titanium-prod..."
cat <<'EOFAPP' | kubectl apply -f -
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
    targetRevision: feat/gcp-deployment
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
EOFAPP

# Create ArgoCD Application for Loki Stack
log "Creating ArgoCD Application for loki-stack..."
cat <<'EOFAPP' | kubectl apply -f -
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
        promtail:
          enabled: true
          config:
            clients:
              - url: http://loki:3100/loki/api/v1/push
        grafana:
          enabled: false
          sidecar:
            datasources:
              enabled: false
        prometheus:
          enabled: false
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOFAPP

# Create ArgoCD Application for Istio Base (CRDs)
log "Creating ArgoCD Application for istio-base..."
cat <<'EOFAPP' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-base
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    chart: base
    repoURL: https://istio-release.storage.googleapis.com/charts
    targetRevision: 1.24.2
    helm:
      releaseName: istio-base
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOFAPP

# Wait for Istio CRDs to be established
log "Waiting for Istio CRDs..."
sleep 10

# Create ArgoCD Application for Istiod (Control Plane)
log "Creating ArgoCD Application for istiod..."
cat <<'EOFAPP' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istiod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    chart: istiod
    repoURL: https://istio-release.storage.googleapis.com/charts
    targetRevision: 1.24.2
    helm:
      releaseName: istiod
      values: |
        pilot:
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOFAPP

# Create ArgoCD Application for Istio Ingress Gateway
log "Creating ArgoCD Application for istio-ingressgateway..."
cat <<'EOFAPP' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-ingressgateway
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    chart: gateway
    repoURL: https://istio-release.storage.googleapis.com/charts
    targetRevision: 1.24.2
    helm:
      releaseName: istio-ingressgateway
      values: |
        labels:
          istio: ingressgateway
        service:
          type: NodePort
          ports:
          - name: http2
            port: 80
            targetPort: 80
            nodePort: 31080
          - name: https
            port: 443
            targetPort: 443
            nodePort: 31443
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOFAPP

# Create ArgoCD Application for kube-prometheus-stack
log "Creating ArgoCD Application for kube-prometheus-stack..."
cat <<'EOFAPP' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    chart: kube-prometheus-stack
    repoURL: https://prometheus-community.github.io/helm-charts
    targetRevision: 79.5.0
    helm:
      releaseName: prometheus
      values: |
        prometheus:
          prometheusSpec:
            resources:
              requests:
                cpu: 100m
                memory: 512Mi
              limits:
                cpu: 500m
                memory: 1Gi
            retention: 7d
            storageSpec:
              volumeClaimTemplate:
                spec:
                  accessModes: ["ReadWriteOnce"]
                  resources:
                    requests:
                      storage: 10Gi
          service:
            type: NodePort
            nodePort: 31090
        grafana:
          enabled: true
          adminPassword: admin
          service:
            type: NodePort
            nodePort: 31300
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
          sidecar:
            datasources:
              enabled: false
          datasources:
            datasources.yaml:
              apiVersion: 1
              datasources:
              - name: Prometheus
                type: prometheus
                url: http://prometheus-kube-prometheus-prometheus:9090
                isDefault: true
              - name: Loki
                type: loki
                url: http://loki.monitoring:3100
                isDefault: false
        alertmanager:
          enabled: true
          alertmanagerSpec:
            resources:
              requests:
                cpu: 50m
                memory: 128Mi
              limits:
                cpu: 200m
                memory: 256Mi
        nodeExporter:
          enabled: true
        kubeStateMetrics:
          enabled: true
        defaultRules:
          create: true
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOFAPP

# Create ArgoCD Application for Kiali
log "Creating ArgoCD Application for kiali..."
cat <<'EOFAPP' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kiali
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    chart: kiali-server
    repoURL: https://kiali.org/helm-charts
    targetRevision: 2.4.0
    helm:
      releaseName: kiali
      values: |
        deployment:
          namespace: istio-system
        external_services:
          prometheus:
            url: http://prometheus-kube-prometheus-prometheus.monitoring:9090
          grafana:
            enabled: true
            url: http://prometheus-grafana.monitoring:80
            in_cluster_url: http://prometheus-grafana.monitoring:80
          tracing:
            enabled: false
        server:
          web_root: /kiali
        service:
          type: NodePort
          node_port: 31200
        auth:
          strategy: anonymous
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOFAPP

log "Bootstrap complete!"
log "ArgoCD UI: http://$PUBLIC_IP:30080"
log "Grafana UI: http://$PUBLIC_IP:31300 (admin/admin)"
log "Prometheus UI: http://$PUBLIC_IP:31090"
log "Kiali UI: http://$PUBLIC_IP:31200"
log "Istio Ingress Gateway: http://$PUBLIC_IP:31080"
log "Get ArgoCD admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
log "ArgoCD will now automatically sync applications from Git"

# Mark installation complete
echo "bootstrap-complete" > /tmp/k3s-status
echo "$(date)" > /tmp/bootstrap-timestamp
