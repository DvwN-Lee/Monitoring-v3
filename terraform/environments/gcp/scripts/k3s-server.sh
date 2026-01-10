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

# Create PostgreSQL secret for titanium-prod
log "Creating PostgreSQL secret..."
kubectl create secret generic postgresql-secret \
  --from-literal=POSTGRES_DB=titanium \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --namespace=titanium-prod \
  --dry-run=client -o yaml | kubectl apply -f -

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

# Create ArgoCD Application for titanium-prod
log "Creating ArgoCD Application for titanium-prod..."
cat <<EOFAPP | kubectl apply -f -
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
    repoURL: $GITOPS_REPO_URL
    targetRevision: $GITOPS_TARGET_REVISION
    path: k8s-manifests/overlays/gcp
  destination:
    server: https://kubernetes.default.svc
    namespace: titanium-prod
  # Issue #39: Bootstrap script에서 생성한 Secret 값 보존
  # ArgoCD selfHeal이 Git의 placeholder 값으로 덮어쓰지 않도록 설정
  ignoreDifferences:
    - group: ""
      kind: Secret
      name: prod-app-secrets
      jsonPointers:
        - /data/JWT_PRIVATE_KEY
        - /data/JWT_PUBLIC_KEY
        - /data/JWT_SECRET_KEY
        - /data/INTERNAL_API_SECRET
        - /data/POSTGRES_PASSWORD
        - /data/REDIS_PASSWORD
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
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOFAPP

# Create ArgoCD Application for Loki Stack
log "Creating ArgoCD Application for loki-stack..."
cat <<EOFAPP | kubectl apply -f -
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
    targetRevision: $LOKI_STACK_VERSION
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
cat <<EOFAPP | kubectl apply -f -
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
    targetRevision: $ISTIO_VERSION
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
cat <<EOFAPP | kubectl apply -f -
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
    targetRevision: $ISTIO_VERSION
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

# Wait for istiod mutating webhook to be ready
log "Waiting for istiod mutating webhook to be ready..."
WEBHOOK_TIMEOUT=120
WEBHOOK_ELAPSED=0
until kubectl get mutatingwebhookconfiguration istio-sidecar-injector >/dev/null 2>&1; do
    if [ $WEBHOOK_ELAPSED -ge $WEBHOOK_TIMEOUT ]; then
        log "Warning: istiod webhook timeout, proceeding anyway..."
        break
    fi
    log "Waiting for istiod webhook... ($WEBHOOK_ELAPSED/$WEBHOOK_TIMEOUT sec)"
    sleep 5
    WEBHOOK_ELAPSED=$((WEBHOOK_ELAPSED + 5))
done
log "istiod mutating webhook is ready"

# Create ArgoCD Application for Istio Ingress Gateway
log "Creating ArgoCD Application for istio-ingressgateway..."
cat <<EOFAPP | kubectl apply -f -
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
    targetRevision: $ISTIO_VERSION
    helm:
      releaseName: istio-ingressgateway
      values: |
        labels:
          istio: ingressgateway
        image:
          registry: docker.io/istio
          repository: proxyv2
          tag: $ISTIO_VERSION
        service:
          type: NodePort
          ports:
          - name: http2
            port: 80
            targetPort: 80
            nodePort: $NODEPORT_ISTIO_HTTP
          - name: https
            port: 443
            targetPort: 443
            nodePort: $NODEPORT_ISTIO_HTTPS
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
cat <<EOFAPP | kubectl apply -f -
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
    targetRevision: $KUBE_PROMETHEUS_VERSION
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
            serviceMonitorSelectorNilUsesHelmValues: false
            podMonitorSelectorNilUsesHelmValues: false
            serviceMonitorNamespaceSelector: {}
            podMonitorNamespaceSelector: {}
          service:
            type: NodePort
            nodePort: $NODEPORT_PROMETHEUS
        grafana:
          enabled: true
          adminPassword: $GRAFANA_ADMIN_PASSWORD
          service:
            type: NodePort
            nodePort: $NODEPORT_GRAFANA
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
cat <<EOFAPP | kubectl apply -f -
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
    targetRevision: $KIALI_VERSION
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
          nodePort: $NODEPORT_KIALI
          port: 20001
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

# Wait for Kiali to be deployed and patch service to NodePort
log "Waiting for Kiali deployment..."
kubectl wait --for=condition=Available deployment/kiali -n istio-system --timeout=300s || log "Warning: Kiali deployment not ready"
log "Patching Kiali service to NodePort:$NODEPORT_KIALI..."
kubectl patch svc kiali -n istio-system --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},{\"op\":\"add\",\"path\":\"/spec/ports/0/nodePort\",\"value\":$NODEPORT_KIALI}]" || log "Warning: Kiali service patch failed"

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
