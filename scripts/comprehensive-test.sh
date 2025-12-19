#!/bin/bash

# Monitoring-v2 프로젝트 종합 테스트 스크립트
# 자동화된 통합 테스트

set -e

# 색상 정의
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 테스트 결과 카운터
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# 로그 함수
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    ((PASSED_TESTS++))
    ((TOTAL_TESTS++))
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
    ((FAILED_TESTS++))
    ((TOTAL_TESTS++))
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# 테스트 시작
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Monitoring-v2 프로젝트 종합 테스트 시작              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Phase 1: 인프라 및 환경 검증
log_section "Phase 1: 인프라 및 환경 검증"

# 1-1. Kubernetes Node 상태
log_info "1-1. Kubernetes Node 상태 확인"
if kubectl get nodes --no-headers | grep -q "Ready"; then
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
    READY_COUNT=$(kubectl get nodes --no-headers | grep "Ready" | wc -l | tr -d ' ')
    if [ "$NODE_COUNT" -eq "$READY_COUNT" ]; then
        log_success "모든 Node ($NODE_COUNT개) Ready 상태"
    else
        log_error "일부 Node가 Ready 상태가 아닙니다 ($READY_COUNT/$NODE_COUNT)"
    fi
else
    log_error "Node 상태 확인 실패"
fi

# 1-2. Namespace 확인
log_info "1-2. 핵심 Namespace 확인"
REQUIRED_NS=("titanium-prod" "monitoring" "istio-system" "argocd")
for ns in "${REQUIRED_NS[@]}"; do
    if kubectl get ns "$ns" &> /dev/null; then
        log_success "Namespace '$ns' 존재"
    else
        log_error "Namespace '$ns' 없음"
    fi
done

# 1-3. PostgreSQL 및 Redis Pod 상태
log_info "1-3. 데이터베이스 및 캐시 Pod 상태 확인"
POSTGRES_STATUS=$(kubectl get pods -n titanium-prod -l app=postgresql --no-headers 2>/dev/null | awk '{print $2}')
if [ "$POSTGRES_STATUS" == "2/2" ]; then
    log_success "PostgreSQL Pod Running (2/2)"
else
    log_error "PostgreSQL Pod 상태 이상: $POSTGRES_STATUS"
fi

REDIS_STATUS=$(kubectl get pods -n titanium-prod -l app=prod-redis --no-headers 2>/dev/null | awk '{print $2}' | head -1)
if [ "$REDIS_STATUS" == "2/2" ]; then
    log_success "Redis Pod Running (2/2)"
else
    log_error "Redis Pod 상태 이상: $REDIS_STATUS"
fi

# 1-4. PVC 상태
log_info "1-4. PVC 상태 확인"
PVC_BOUND=$(kubectl get pvc -n titanium-prod,monitoring --no-headers 2>/dev/null | grep "Bound" | wc -l | tr -d ' ')
PVC_TOTAL=$(kubectl get pvc -n titanium-prod,monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$PVC_BOUND" -gt 0 ]; then
    log_success "PVC Bound 상태: $PVC_BOUND/$PVC_TOTAL"
else
    log_error "PVC Bound 실패"
fi

# Phase 2: 애플리케이션 배포 및 기본 기능 검증
log_section "Phase 2: 애플리케이션 배포 및 기본 기능 검증"

# 2-1. 애플리케이션 Pod 상태
log_info "2-1. 애플리케이션 Pod 상태 확인"
SERVICES=("prod-api-gateway" "prod-auth-service" "prod-blog-service" "prod-user-service")
for svc in "${SERVICES[@]}"; do
    POD_COUNT=$(kubectl get pods -n titanium-prod -l "app=${svc}" --no-headers 2>/dev/null | grep "2/2.*Running" | wc -l | tr -d ' ')
    if [ "$POD_COUNT" -gt 0 ]; then
        log_success "${svc}: ${POD_COUNT}개 Pod Running"
    else
        log_error "${svc}: Pod가 Running 상태가 아닙니다"
    fi
done

# Phase 3: Service 간 통신 및 라우팅 검증
log_section "Phase 3: Service 간 통신 및 라우팅 검증"

# 3-1. Istio Ingress Gateway IP 확인
log_info "3-1. Istio Ingress Gateway IP 확인"
INGRESS_IP=$(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -n "$INGRESS_IP" ]; then
    log_success "Ingress Gateway IP: $INGRESS_IP"
else
    log_error "Ingress Gateway IP를 가져올 수 없습니다"
    exit 1
fi

# 3-2. User-Service 라우팅 테스트
log_info "3-2. User-Service 라우팅 테스트 (/api/users/)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${INGRESS_IP}/api/users/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "307" ]; then
    log_success "User-Service 라우팅 성공 (HTTP $HTTP_CODE)"
else
    log_error "User-Service 라우팅 실패 (HTTP $HTTP_CODE)"
fi

# 3-3. Blog-Service 라우팅 테스트
log_info "3-3. Blog-Service 라우팅 테스트 (/blog/)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${INGRESS_IP}/blog/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "307" ]; then
    log_success "Blog-Service 라우팅 성공 (HTTP $HTTP_CODE)"
else
    log_error "Blog-Service 라우팅 실패 (HTTP $HTTP_CODE)"
fi

# 3-4. Auth API 라우팅 테스트
log_info "3-4. Auth API 라우팅 테스트 (/blog/api/)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${INGRESS_IP}/blog/api/categories" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" == "200" ]; then
    log_success "Auth API 라우팅 성공 (HTTP $HTTP_CODE)"
else
    log_error "Auth API 라우팅 실패 (HTTP $HTTP_CODE)"
fi

# Phase 4: Service Mesh 고급 기능 검증
log_section "Phase 4: Service Mesh 고급 기능 검증"

# 4-1. HPA 설정 확인
log_info "4-1. HPA 설정 확인"
HPA_COUNT=$(kubectl get hpa -n titanium-prod --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$HPA_COUNT" -ge 4 ]; then
    log_success "HPA 설정됨: ${HPA_COUNT}개"
else
    log_warning "HPA 개수가 예상보다 적습니다: ${HPA_COUNT}개"
fi

# 4-2. Istio VirtualService 확인
log_info "4-2. Istio VirtualService 확인"
VS_COUNT=$(kubectl get virtualservice -n titanium-prod --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$VS_COUNT" -gt 0 ]; then
    log_success "VirtualService 설정됨: ${VS_COUNT}개"
else
    log_error "VirtualService가 없습니다"
fi

# Phase 5: 관측성 스택 검증
log_section "Phase 5: 관측성 스택 검증"

# 5-1. Prometheus Pod 확인
log_info "5-1. Prometheus Pod 상태 확인"
PROM_STATUS=$(kubectl get pods -n monitoring -l "app.kubernetes.io/name=prometheus" --no-headers 2>/dev/null | awk '{print $2}' | head -1)
if [[ "$PROM_STATUS" == *"/"* ]]; then
    log_success "Prometheus Pod Running ($PROM_STATUS)"
else
    log_error "Prometheus Pod 상태 이상"
fi

# 5-2. Grafana Pod 확인
log_info "5-2. Grafana Pod 상태 확인"
GRAFANA_STATUS=$(kubectl get pods -n monitoring -l "app.kubernetes.io/name=grafana" --no-headers 2>/dev/null | awk '{print $2}' | head -1)
if [[ "$GRAFANA_STATUS" == *"/"* ]]; then
    log_success "Grafana Pod Running ($GRAFANA_STATUS)"
else
    log_error "Grafana Pod 상태 이상"
fi

# 5-3. Loki Pod 확인
log_info "5-3. Loki Pod 상태 확인"
LOKI_COUNT=$(kubectl get pods -n monitoring -l "app.kubernetes.io/name=loki" --no-headers 2>/dev/null | grep "Running" | wc -l | tr -d ' ')
if [ "$LOKI_COUNT" -gt 0 ]; then
    log_success "Loki Pod Running: ${LOKI_COUNT}개"
else
    log_warning "Loki Pod 확인 필요"
fi

# 5-4. ServiceMonitor 확인
log_info "5-4. ServiceMonitor 확인"
SM_COUNT=$(kubectl get servicemonitor -n monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$SM_COUNT" -ge 4 ]; then
    log_success "ServiceMonitor 설정됨: ${SM_COUNT}개"
else
    log_warning "ServiceMonitor 개수 확인 필요: ${SM_COUNT}개"
fi

# Phase 6: GitOps 검증
log_section "Phase 6: GitOps (Argo CD) 검증"

# 6-1. Argo CD Pod 확인
log_info "6-1. Argo CD Pod 상태 확인"
ARGOCD_COUNT=$(kubectl get pods -n argocd --no-headers 2>/dev/null | grep "Running" | wc -l | tr -d ' ')
if [ "$ARGOCD_COUNT" -gt 0 ]; then
    log_success "Argo CD Pod Running: ${ARGOCD_COUNT}개"
else
    log_error "Argo CD Pod가 Running 상태가 아닙니다"
fi

# 6-2. Argo CD Application 확인
log_info "6-2. Argo CD Application 확인"
if kubectl get application -n argocd titanium-app &> /dev/null; then
    APP_STATUS=$(kubectl get application -n argocd titanium-app -o jsonpath='{.status.health.status}' 2>/dev/null)
    APP_SYNC=$(kubectl get application -n argocd titanium-app -o jsonpath='{.status.sync.status}' 2>/dev/null)
    if [ "$APP_STATUS" == "Healthy" ] && [ "$APP_SYNC" == "Synced" ]; then
        log_success "Argo CD Application: Healthy & Synced"
    else
        log_warning "Argo CD Application 상태: Health=$APP_STATUS, Sync=$APP_SYNC"
    fi
else
    log_error "Argo CD Application 'titanium-app'을 찾을 수 없습니다"
fi

# 테스트 결과 요약
log_section "테스트 결과 요약"
echo ""
echo -e "${BLUE}총 테스트:${NC} $TOTAL_TESTS"
echo -e "${GREEN}성공:${NC} $PASSED_TESTS"
echo -e "${RED}실패:${NC} $FAILED_TESTS"
echo ""

SUCCESS_RATE=$(( PASSED_TESTS * 100 / TOTAL_TESTS ))
echo -e "${BLUE}성공률:${NC} ${SUCCESS_RATE}%"
echo ""

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  모든 테스트 통과! 시스템이 정상 작동 중입니다.       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  일부 테스트 실패. 로그를 확인해주세요.               ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi
