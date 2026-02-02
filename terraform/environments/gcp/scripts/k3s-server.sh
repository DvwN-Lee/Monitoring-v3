#!/bin/bash
set -e

# Complete K3s + ArgoCD + GitOps Bootstrap Script for GCP
# This script runs on the master node via startup script and sets up the entire stack

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/k3s-bootstrap.log
}

log "Starting complete k3s + ArgoCD bootstrap..."

# Idempotency guard: 이미 Bootstrap이 완료된 경우 재실행 방지
BOOTSTRAP_MARKER="/var/lib/k3s-bootstrap-done"
if [ -f "$BOOTSTRAP_MARKER" ]; then
  log "Bootstrap already completed (marker: $BOOTSTRAP_MARKER). Skipping."
  exit 0
fi

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
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${k3s_version}" K3S_TOKEN="$K3S_TOKEN" sh -s - server \
    --write-kubeconfig-mode 600 \
    --disable traefik \
    --tls-san "$PRIVATE_IP" \
    --tls-san "$PUBLIC_IP"
else
  log "Installing k3s with private IP only"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${k3s_version}" K3S_TOKEN="$K3S_TOKEN" sh -s - server \
    --write-kubeconfig-mode 600 \
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

# Master node 등록 대기 (API server ready 직후 node 등록에 수 초 소요될 수 있음)
for i in $(seq 1 30); do
  MASTER_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [ -n "$MASTER_NODE" ] && break
  sleep 2
done
if [ -z "$MASTER_NODE" ]; then
  log "ERROR: Master node not registered after 60 seconds"
  exit 1
fi

# Taint master node: 일반 워크로드는 Worker에서만 실행
# ArgoCD, kube-system Pod는 toleration으로 Master에서 실행 유지
log "Tainting master node ($MASTER_NODE) to prevent general workload scheduling..."
kubectl taint nodes "$MASTER_NODE" node-role.kubernetes.io/master=true:NoSchedule --overwrite

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

# Patch all ArgoCD Deployments/StatefulSets with master node toleration
log "Adding master node toleration to ArgoCD workloads..."
TOLERATION_PATCH='{"spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]}}}}'
for deploy in $(kubectl get deployments -n argocd -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch deployment "$deploy" -n argocd --type=merge -p="$TOLERATION_PATCH" 2>/dev/null
done
for sts in $(kubectl get statefulsets -n argocd -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch statefulset "$sts" -n argocd --type=merge -p="$TOLERATION_PATCH" 2>/dev/null
done
log "ArgoCD toleration patching complete"

# Generate JWT RS256 Key Pair for auth-service
log "Generating JWT RS256 key pair..."
JWT_TEMP_DIR=$(mktemp -d)
openssl genrsa -out "$JWT_TEMP_DIR/jwt-private.pem" 2048 2>/dev/null
openssl rsa -in "$JWT_TEMP_DIR/jwt-private.pem" -pubout -out "$JWT_TEMP_DIR/jwt-public.pem" 2>/dev/null

# Secret 값 생성 (GCP Secret Manager가 단일 소스)
JWT_SECRET_KEY="$(openssl rand -hex 32)"
INTERNAL_API_SECRET="$(openssl rand -hex 32)"
REDIS_PASSWORD="$(openssl rand -hex 16)"

# GCP Secret Manager에 Secret 값 업로드
# ExternalSecret이 이 값을 가져와 prod-app-secrets Kubernetes Secret을 자동 생성
log "Uploading secrets to GCP Secret Manager (single source of truth)..."

upload_secret() {
  local sm_name="$1"
  local value="$2"
  echo -n "$value" | gcloud secrets versions add "$sm_name" --data-file=- 2>/dev/null || \
    echo -n "$value" | gcloud secrets create "$sm_name" --data-file=- || \
    log "ERROR: Failed to upload secret $sm_name"
}

upload_secret "titanium-jwt-private-key" "$(cat "$JWT_TEMP_DIR/jwt-private.pem")"
upload_secret "titanium-jwt-public-key" "$(cat "$JWT_TEMP_DIR/jwt-public.pem")"
upload_secret "titanium-jwt-secret-key" "$JWT_SECRET_KEY"
upload_secret "titanium-internal-api-secret" "$INTERNAL_API_SECRET"
upload_secret "titanium-redis-password" "$REDIS_PASSWORD"
upload_secret "titanium-postgres-user" "postgres"
upload_secret "titanium-postgres-password" "$POSTGRES_PASSWORD"

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
kubectl label namespace istio-system istio-injection=enabled --overwrite
kubectl create secret tls titanium-tls-credential \
  --key="$TLS_TEMP_DIR/tls.key" \
  --cert="$TLS_TEMP_DIR/tls.crt" \
  --namespace=istio-system \
  --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$TLS_TEMP_DIR"
log "TLS and JWT secrets created successfully"

# Wait for all Worker nodes to join and be Ready before deploying workloads
EXPECTED_WORKERS="${worker_count}"
log "Waiting for $EXPECTED_WORKERS Worker node(s) to join the cluster..."
for i in $(seq 1 120); do
  READY_WORKERS=$(kubectl get nodes --no-headers 2>/dev/null | grep -v master | grep -c " Ready" || echo 0)
  if [ "$READY_WORKERS" -ge "$EXPECTED_WORKERS" ]; then
    log "All Worker nodes Ready: $READY_WORKERS/$EXPECTED_WORKERS"
    break
  fi
  if [ "$i" -eq 120 ]; then
    log "WARNING: Only $READY_WORKERS/$EXPECTED_WORKERS Worker nodes Ready after 10 minutes. Proceeding."
  fi
  sleep 5
done
kubectl get nodes
log "Cluster nodes: $(kubectl get nodes --no-headers | wc -l) total"

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

# ExternalSecret이 prod-app-secrets를 생성할 때까지 대기
# ArgoCD가 ExternalSecret operator와 titanium-prod application을 sync한 후 Secret이 자동 생성됨
log "Waiting for ExternalSecret to create prod-app-secrets..."
for i in $(seq 1 60); do
  if kubectl get secret prod-app-secrets -n titanium-prod >/dev/null 2>&1; then
    log "prod-app-secrets created by ExternalSecret (attempt $i)"
    break
  fi
  if [ "$i" -eq 60 ]; then
    log "WARNING: prod-app-secrets not created after 5 minutes. ExternalSecret sync may be delayed."
  fi
  sleep 5
done

# Istio Gateway sidecar injection 확인
# istiod webhook 등록 전에 gateway Pod가 생성되면 image가 'auto'로 남음
log "Verifying Istio Gateway sidecar injection..."
for i in $(seq 1 30); do
  GW_IMAGE=$(kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)
  if [ "$GW_IMAGE" = "auto" ] || echo "$GW_IMAGE" | grep -q "auto"; then
    log "Gateway image is 'auto' (attempt $i), restarting for injection..."
    kubectl delete pod -n istio-system -l app=istio-ingressgateway >/dev/null 2>&1
    sleep 10
  elif [ -n "$GW_IMAGE" ]; then
    log "Gateway image verified: $GW_IMAGE"
    break
  else
    sleep 5
  fi
done

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
touch "$BOOTSTRAP_MARKER"
