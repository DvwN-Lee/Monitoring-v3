#!/bin/bash
set -e

# Complete K3s + ArgoCD + GitOps Bootstrap Script for GCP
# This script runs on the master node via startup script and sets up the entire stack

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/k3s-bootstrap.log
}

log "Starting complete k3s + ArgoCD bootstrap..."

# Variables from Terraform
K3S_TOKEN="${k3s_token}"
POSTGRES_PASSWORD="${postgres_password}"
GRAFANA_ADMIN_PASSWORD="${grafana_admin_password}"
GITOPS_REPO_URL="${gitops_repo_url}"
GITOPS_TARGET_REVISION="${gitops_target_revision}"

# Helm Chart Versions
ARGOCD_VERSION="${helm_versions.argocd}"
ISTIO_VERSION="${helm_versions.istio}"
LOKI_STACK_VERSION="${helm_versions.loki_stack}"
KUBE_PROMETHEUS_VERSION="${helm_versions.kube_prometheus}"
KIALI_VERSION="${helm_versions.kiali}"

# NodePort Configuration
NODEPORT_ARGOCD="${nodeports.argocd}"
NODEPORT_GRAFANA="${nodeports.grafana}"
NODEPORT_PROMETHEUS="${nodeports.prometheus}"
NODEPORT_KIALI="${nodeports.kiali}"
NODEPORT_ISTIO_HTTP="${nodeports.istio_http}"
NODEPORT_ISTIO_HTTPS="${nodeports.istio_https}"

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
log "Installing ArgoCD $ARGOCD_VERSION..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml

# Wait for ArgoCD to be ready
log "Waiting for ArgoCD deployments..."
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=600s || log "Warning: ArgoCD may not be fully ready"

# Patch ArgoCD server to NodePort 30080
log "Configuring ArgoCD server as NodePort:30080..."
kubectl patch svc argocd-server -n argocd --type='json' -p="[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},{\"op\":\"add\",\"path\":\"/spec/ports/0/nodePort\",\"value\":$NODEPORT_ARGOCD}]"

# Make ArgoCD server insecure (no TLS) for easier access
kubectl patch deployment argocd-server -n argocd --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

# Generate JWT RS256 Key Pair for auth-service
log "Generating JWT RS256 key pair..."
JWT_TEMP_DIR=$(mktemp -d)
openssl genrsa -out "$JWT_TEMP_DIR/jwt-private.pem" 2048 2>/dev/null
openssl rsa -in "$JWT_TEMP_DIR/jwt-private.pem" -pubout -out "$JWT_TEMP_DIR/jwt-public.pem" 2>/dev/null

# Create app-secrets with JWT RS256 keys
# Issue #39: --from-file 사용으로 이중 base64 인코딩 문제 해결
# kubectl --from-file은 파일 내용을 자동으로 base64 인코딩하여 Secret에 저장
log "Creating app-secrets with JWT RS256 keys..."
kubectl create secret generic prod-app-secrets \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=JWT_SECRET_KEY="$(openssl rand -hex 32)" \
  --from-file=JWT_PRIVATE_KEY="$JWT_TEMP_DIR/jwt-private.pem" \
  --from-file=JWT_PUBLIC_KEY="$JWT_TEMP_DIR/jwt-public.pem" \
  --from-literal=INTERNAL_API_SECRET="$(openssl rand -hex 32)" \
  --from-literal=REDIS_PASSWORD="$(openssl rand -hex 16)" \
  --namespace=titanium-prod \
  --dry-run=client -o yaml | kubectl apply -f -
## GCP Secret Manager에 Secret 값 업로드 (ExternalSecret 연동)
log "Uploading secrets to GCP Secret Manager..."
cat "$JWT_TEMP_DIR/jwt-private.pem" | gcloud secrets versions add titanium-jwt-private-key --data-file=- 2>/dev/null || \
  gcloud secrets create titanium-jwt-private-key --data-file="$JWT_TEMP_DIR/jwt-private.pem"
cat "$JWT_TEMP_DIR/jwt-public.pem" | gcloud secrets versions add titanium-jwt-public-key --data-file=- 2>/dev/null || \
  gcloud secrets create titanium-jwt-public-key --data-file="$JWT_TEMP_DIR/jwt-public.pem"

# JWT_SECRET_KEY, INTERNAL_API_SECRET, REDIS_PASSWORD는 kubectl create 시 사용한 값을 재생성하여 동일 값 보장이 어려우므로
# Secret에서 추출하여 GCP SM에 업로드
for secret_key in JWT_SECRET_KEY INTERNAL_API_SECRET REDIS_PASSWORD POSTGRES_USER POSTGRES_PASSWORD; do
  sm_name="titanium-$(echo "$secret_key" | tr '[:upper:]_' '[:lower:]-')"
  value=$(kubectl get secret prod-app-secrets -n titanium-prod -o jsonpath="{.data.$secret_key}" | base64 -d)
  echo -n "$value" | gcloud secrets versions add "$sm_name" --data-file=- 2>/dev/null || \
    echo -n "$value" | gcloud secrets create "$sm_name" --data-file=-
done
log "GCP Secret Manager upload completed"

rm -rf "$JWT_TEMP_DIR"

# Generate TLS Certificate for Istio Gateway
log "Generating TLS certificate for Istio Gateway..."
TLS_TEMP_DIR=$(mktemp -d)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$TLS_TEMP_DIR/tls.key" \
  -out "$TLS_TEMP_DIR/tls.crt" \
  -subj "/CN=titanium.local/O=Titanium" \
  -addext "subjectAltName=DNS:titanium.local,DNS:*.titanium.local,DNS:localhost,IP:$PUBLIC_IP" 2>/dev/null

# Create TLS Secret in istio-system namespace
log "Creating TLS secret in istio-system..."
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret tls titanium-tls-credential \
  --key="$TLS_TEMP_DIR/tls.key" \
  --cert="$TLS_TEMP_DIR/tls.crt" \
  --namespace=istio-system \
  --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$TLS_TEMP_DIR"
log "TLS and JWT secrets created successfully"

# Create Root Application (App of Apps Pattern)
log "Creating Root Application for App of Apps Pattern..."
cat <<EOFAPP | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $GITOPS_REPO_URL
    targetRevision: $GITOPS_TARGET_REVISION
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOFAPP

log "Root Application created. ArgoCD will automatically create all child applications from apps/ directory."

log "Bootstrap complete!"
log "ArgoCD UI: http://$PUBLIC_IP:$NODEPORT_ARGOCD"
log "Grafana UI: http://$PUBLIC_IP:$NODEPORT_GRAFANA"
log "Prometheus UI: http://$PUBLIC_IP:$NODEPORT_PROMETHEUS"
log "Kiali UI: http://$PUBLIC_IP:$NODEPORT_KIALI"
log "Istio Ingress Gateway: http://$PUBLIC_IP:$NODEPORT_ISTIO_HTTP"
log "Get ArgoCD admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
log "ArgoCD will now automatically sync applications from Git"

# Mark installation complete
echo "bootstrap-complete" > /tmp/k3s-status
echo "$(date)" > /tmp/bootstrap-timestamp
