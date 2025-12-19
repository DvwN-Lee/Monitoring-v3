#!/bin/bash

echo "========================================"
echo "IaC 배포 상태 검증 스크립트"
echo "========================================"
echo ""

# kubeconfig 설정
export KUBECONFIG=~/.kube/config-solid-cloud

# 색상 코드
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 결과 카운터
PASSED=0
FAILED=0

# 검증 함수
check_status() {
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ PASS${NC}"
    ((PASSED++))
  else
    echo -e "${RED}✗ FAIL${NC}"
    ((FAILED++))
  fi
}

echo "1. Kubernetes Cluster 연결 테스트"
echo "-----------------------------------"
kubectl cluster-info > /dev/null 2>&1
check_status
echo ""

echo "2. Node 상태 확인"
echo "-----------------------------------"
kubectl get nodes
EXPECTED_NODES=3
ACTUAL_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
if [ "$ACTUAL_NODES" -eq "$EXPECTED_NODES" ]; then
  echo -e "${GREEN}✓ Node 수 확인: $ACTUAL_NODES/$EXPECTED_NODES${NC}"
  ((PASSED++))
else
  echo -e "${RED}✗ Node 수 불일치: $ACTUAL_NODES/$EXPECTED_NODES${NC}"
  ((FAILED++))
fi
echo ""

echo "3. Namespace 확인"
echo "-----------------------------------"
for ns in titanium-prod monitoring argocd; do
  kubectl get ns $ns > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} $ns namespace exists"
    ((PASSED++))
  else
    echo -e "${RED}✗${NC} $ns namespace missing"
    ((FAILED++))
  fi
done
echo ""

echo "4. PostgreSQL 상태 확인"
echo "-----------------------------------"
kubectl get pods -n titanium-prod -l app=postgresql
kubectl wait --for=condition=ready pod -l app=postgresql -n titanium-prod --timeout=10s > /dev/null 2>&1
check_status
echo ""

echo "5. PostgreSQL Database Schema 확인"
echo "-----------------------------------"
TABLES=$(kubectl exec postgresql-0 -n titanium-prod -- psql -U postgres -d titanium -t -c "\dt" 2>/dev/null | grep -c "table")
if [ "$TABLES" -ge 3 ]; then
  echo -e "${GREEN}✓ Database Schema 확인: $TABLES 테이블 존재${NC}"
  ((PASSED++))
else
  echo -e "${RED}✗ Database Schema 불완전: $TABLES 테이블${NC}"
  ((FAILED++))
fi

CATEGORIES=$(kubectl exec postgresql-0 -n titanium-prod -- psql -U postgres -d titanium -t -c "SELECT COUNT(*) FROM categories;" 2>/dev/null | tr -d ' ')
if [ "$CATEGORIES" -gt 0 ]; then
  echo -e "${GREEN}✓ Categories 데이터 확인: $CATEGORIES 카테고리${NC}"
  ((PASSED++))
else
  echo -e "${RED}✗ Categories 데이터 없음${NC}"
  ((FAILED++))
fi
echo ""

echo "6. Application Secrets 확인"
echo "-----------------------------------"
kubectl get secret prod-app-secrets -n titanium-prod > /dev/null 2>&1
check_status
echo ""

echo "7. Application Pods 확인"
echo "-----------------------------------"
kubectl get pods -n titanium-prod
RUNNING_PODS=$(kubectl get pods -n titanium-prod --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
TOTAL_PODS=$(kubectl get pods -n titanium-prod --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$RUNNING_PODS" -eq "$TOTAL_PODS" ] && [ "$TOTAL_PODS" -gt 0 ]; then
  echo -e "${GREEN}✓ 모든 Pod Running: $RUNNING_PODS/$TOTAL_PODS${NC}"
  ((PASSED++))
else
  echo -e "${RED}✗ Pod 상태 불량: $RUNNING_PODS/$TOTAL_PODS Running${NC}"
  ((FAILED++))
fi
echo ""

echo "8. Argo CD 확인"
echo "-----------------------------------"
kubectl get pods -n argocd | head -10
ARGOCD_READY=$(kubectl get pods -n argocd --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$ARGOCD_READY" -ge 7 ]; then
  echo -e "${GREEN}✓ Argo CD 정상: $ARGOCD_READY pods running${NC}"
  ((PASSED++))
else
  echo -e "${YELLOW}⚠ Argo CD 확인 필요: $ARGOCD_READY pods running${NC}"
  ((FAILED++))
fi
echo ""

echo "9. Loki Stack 확인"
echo "-----------------------------------"
kubectl get pods -n monitoring
LOKI_READY=$(kubectl get pods -n monitoring -l app=loki --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
PROMTAIL_READY=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$LOKI_READY" -ge 1 ]; then
  echo -e "${GREEN}✓ Loki 정상: $LOKI_READY pods running${NC}"
  ((PASSED++))
else
  echo -e "${RED}✗ Loki 상태 불량${NC}"
  ((FAILED++))
fi

if [ "$PROMTAIL_READY" -ge 1 ]; then
  echo -e "${GREEN}✓ Promtail 정상: $PROMTAIL_READY pods running${NC}"
  ((PASSED++))
else
  echo -e "${RED}✗ Promtail 상태 불량${NC}"
  ((FAILED++))
fi
echo ""

echo "10. Loki Stack Application Sync 상태"
echo "-----------------------------------"
SYNC_STATUS=$(kubectl get application loki-stack -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)
HEALTH_STATUS=$(kubectl get application loki-stack -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null)

if [ "$SYNC_STATUS" = "Synced" ]; then
  echo -e "${GREEN}✓ Sync Status: $SYNC_STATUS${NC}"
  ((PASSED++))
else
  echo -e "${RED}✗ Sync Status: $SYNC_STATUS${NC}"
  ((FAILED++))
fi

if [ "$HEALTH_STATUS" = "Healthy" ]; then
  echo -e "${GREEN}✓ Health Status: $HEALTH_STATUS${NC}"
  ((PASSED++))
else
  echo -e "${RED}✗ Health Status: $HEALTH_STATUS${NC}"
  ((FAILED++))
fi
echo ""

echo "========================================"
echo "검증 결과 요약"
echo "========================================"
echo -e "${GREEN}통과: $PASSED${NC}"
echo -e "${RED}실패: $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
  echo -e "${GREEN}✓ 모든 검증 통과!${NC}"
  exit 0
else
  echo -e "${RED}✗ $FAILED 개 항목 실패${NC}"
  exit 1
fi
