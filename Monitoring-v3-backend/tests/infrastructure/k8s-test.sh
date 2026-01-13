#!/bin/bash

# Level 4: Kubernetes Resources Test
# Kubernetes Cluster의 기본 리소스 상태를 검증합니다

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Test result
FAILED=0

# Logging functions
log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED=1
}

echo "=== Kubernetes Resources Test ==="

# Test 1: Node Status
echo "Test: Node Status"
if kubectl get nodes --no-headers | awk '{print $2}' | grep -qv "Ready"; then
    log_error "One or more nodes are not Ready"
else
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
    log_success "All ${NODE_COUNT} nodes are Ready"
fi

# Test 2: Namespaces
echo "Test: Critical Namespaces"
REQUIRED_NS=("titanium-prod" "monitoring" "istio-system" "argocd")
for ns in "${REQUIRED_NS[@]}"; do
    if kubectl get namespace "$ns" &> /dev/null; then
        log_success "Namespace '${ns}' exists"
    else
        log_error "Namespace '${ns}' not found"
    fi
done

# Test 3: Application Pods (titanium-prod)
echo "Test: Application Pods"
if kubectl get pods -n titanium-prod --no-headers 2>/dev/null | grep -qv "Running"; then
    log_error "Some pods in titanium-prod are not Running"
else
    POD_COUNT=$(kubectl get pods -n titanium-prod --no-headers 2>/dev/null | wc -l | tr -d ' ')
    log_success "All ${POD_COUNT} application pods are Running"
fi

# Test 4: PostgreSQL Pod
echo "Test: PostgreSQL Pod"
if kubectl get pods -l app=postgresql -n titanium-prod --no-headers 2>/dev/null | grep -q "Running"; then
    log_success "PostgreSQL pod is Running"
else
    log_error "PostgreSQL pod is not Running"
fi

# Test 5: Redis Pod
echo "Test: Redis Pod"
if kubectl get pods -l app=redis -n titanium-prod --no-headers 2>/dev/null | grep -q "Running"; then
    log_success "Redis pod is Running"
else
    log_error "Redis pod is not Running"
fi

# Test 6: PVC Status
echo "Test: PVC Status"
if kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -qv "Bound"; then
    log_error "Some PVCs are not Bound"
else
    PVC_COUNT=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
    log_success "All ${PVC_COUNT} PVCs are Bound"
fi

# Test 7: HPA (Horizontal Pod Autoscaler)
# echo "Test: HPA"
# HPA_COUNT=$(kubectl get hpa -n titanium-prod --no-headers 2>/dev/null | wc -l | tr -d ' ')
# if [ "$HPA_COUNT" -ge 4 ]; then
#     log_success "${HPA_COUNT} HPAs configured"
# else
#     echo -e "${NC}[WARN] Expected at least 4 HPAs, found ${HPA_COUNT}"
# fi

# Exit with appropriate code
if [ $FAILED -eq 1 ]; then
    echo ""
    echo "Kubernetes Resources Test: FAILED"
    exit 1
else
    echo ""
    echo "Kubernetes Resources Test: PASSED"
    exit 0
fi
