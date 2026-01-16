#!/bin/bash
set -e

# Monitoring 스택 자동 배포 스크립트
# ArgoCD 설치 후 Monitoring Application 배포

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# kubectl 연결 확인
check_cluster_connection() {
    log_info "Cluster 연결 확인 중..."
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cluster에 연결할 수 없습니다. kubeconfig를 확인하세요."
        exit 1
    fi
    log_info "Cluster 연결 확인 완료"
}

# ArgoCD 설치
install_argocd() {
    log_info "[1/5] ArgoCD 설치 확인..."

    if kubectl get ns argocd &>/dev/null; then
        log_info "ArgoCD가 이미 설치되어 있습니다."
        return 0
    fi

    log_warn "ArgoCD 설치 중..."
    kubectl create namespace argocd
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    log_info "ArgoCD 준비 대기 중... (최대 5분)"
    kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

    # 초기 admin 비밀번호 출력
    log_info "ArgoCD 초기 비밀번호:"
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    echo ""
}

# Monitoring namespace 생성
create_monitoring_namespace() {
    log_info "[2/5] Monitoring namespace 생성..."
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
}

# ArgoCD Applications 배포
deploy_applications() {
    log_info "[3/5] ArgoCD Applications 배포..."
    # Grafana Secret 먼저 배포 (prometheus-stack에서 참조)
    kubectl apply -f "${PROJECT_ROOT}/k8s-manifests/overlays/gcp/monitoring/grafana-secret.yaml"
    # Application YAML 파일 배포 (kustomization.yaml 제외)
    kubectl apply -f "${PROJECT_ROOT}/k8s-manifests/overlays/gcp/monitoring/prometheus-app.yaml"
    kubectl apply -f "${PROJECT_ROOT}/k8s-manifests/overlays/gcp/monitoring/loki-app.yaml"
    kubectl apply -f "${PROJECT_ROOT}/k8s-manifests/overlays/gcp/monitoring/promtail-app.yaml"
}

# 동기화 대기
wait_for_sync() {
    log_info "[4/5] ArgoCD 동기화 대기 중... (최대 10분)"

    # Application이 생성될 때까지 대기
    sleep 10

    # Prometheus Application 동기화 대기
    if kubectl get application prometheus-stack -n argocd &>/dev/null; then
        kubectl wait --for=jsonpath='{.status.sync.status}'=Synced \
            application/prometheus-stack -n argocd --timeout=600s || true
    fi

    # Loki Application 동기화 대기
    if kubectl get application loki -n argocd &>/dev/null; then
        kubectl wait --for=jsonpath='{.status.sync.status}'=Synced \
            application/loki -n argocd --timeout=300s || true
    fi
}

# 상태 확인
check_status() {
    log_info "[5/5] 배포 상태 확인..."

    echo ""
    log_info "=== ArgoCD Applications ==="
    kubectl get applications -n argocd

    echo ""
    log_info "=== Monitoring Pods ==="
    kubectl get pods -n monitoring

    echo ""
    log_info "=== 접근 정보 ==="
    echo "ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
    echo "Grafana:   kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80"
    echo "Prometheus: kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090"
}

# 메인 실행
main() {
    echo "========================================"
    echo "  Monitoring 스택 자동 배포"
    echo "========================================"
    echo ""

    check_cluster_connection
    install_argocd
    create_monitoring_namespace
    deploy_applications
    wait_for_sync
    check_status

    echo ""
    log_info "배포 완료!"
}

main "$@"
