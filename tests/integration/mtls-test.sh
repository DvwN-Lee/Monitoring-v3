#!/bin/bash

# Level 2: mTLS Verification Test
# Istio Service Mesh mTLS 설정을 검증합니다

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

echo "=== mTLS Verification Test ==="

# Test 1: PeerAuthentication STRICT mode
echo "Test: PeerAuthentication Mode"
PA_MODE=$(kubectl get peerauthentication -n titanium-prod -o jsonpath='{.items[*].spec.mtls.mode}' 2>/dev/null)
if [[ "$PA_MODE" == *"STRICT"* ]]; then
    log_success "PeerAuthentication mode: STRICT"
else
    log_error "PeerAuthentication mode is not STRICT: ${PA_MODE}"
fi

# Test 2: Sidecar Injection (Deployment pods only, excludes StatefulSet like PostgreSQL)
echo "Test: Sidecar Injection"
# Check only Deployment pods (exclude StatefulSet pods like postgresql which intentionally skip sidecar)
PODS_WITHOUT_SIDECAR=$(kubectl get pods -n titanium-prod --no-headers 2>/dev/null | grep -v "2/2" | grep -E "^prod-(api|auth|user|blog|redis)" | wc -l | tr -d ' ')
if [ "$PODS_WITHOUT_SIDECAR" -eq 0 ]; then
    log_success "All Deployment pods have istio-proxy sidecar (2/2)"
else
    log_error "${PODS_WITHOUT_SIDECAR} Deployment pods missing istio-proxy sidecar"
fi

# Info: StatefulSet pods without sidecar (expected)
STATEFULSET_PODS=$(kubectl get pods -n titanium-prod --no-headers 2>/dev/null | grep -v "2/2" | grep -E "^prod-postgresql" | wc -l | tr -d ' ')
if [ "$STATEFULSET_PODS" -gt 0 ]; then
    echo -e "${NC}[INFO] ${STATEFULSET_PODS} StatefulSet pod(s) without sidecar (expected for database)"
fi

# Test 3: Istio Proxy Config
echo "Test: Istio Proxy mTLS Config"
POD_NAME=$(kubectl get pods -n titanium-prod -l app=blog-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_NAME" ]; then
    if kubectl exec -n titanium-prod "$POD_NAME" -c istio-proxy -- \
        curl -s localhost:15000/config_dump 2>/dev/null | grep -q "cluster.*outbound"; then
        log_success "Istio proxy configuration verified"
    else
        log_error "Istio proxy configuration check failed"
    fi
else
    log_error "No pods found for proxy config test"
fi

# Exit with appropriate code
if [ $FAILED -eq 1 ]; then
    echo ""
    echo "mTLS Verification Test: FAILED"
    exit 1
else
    echo ""
    echo "mTLS Verification Test: PASSED"
    exit 0
fi
