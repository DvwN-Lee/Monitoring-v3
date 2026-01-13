#!/bin/bash
set -e

# Complete K3s + ArgoCD + GitOps Bootstrap Script
# This script runs on the master node via cloud-init and sets up the entire stack

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
  PUBLIC_IP=$(curl -sf -H "DomainId: 1" http://data-server.cloudstack.internal/latest/meta-data/public-ipv4 2>/dev/null || echo "")
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

log "Bootstrap complete!"
log "ArgoCD UI: http://$PUBLIC_IP:30080"
log "Get ArgoCD admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
log "ArgoCD will now automatically sync applications from Git"

# Mark installation complete
echo "bootstrap-complete" > /tmp/k3s-status
echo "$(date)" > /tmp/bootstrap-timestamp
