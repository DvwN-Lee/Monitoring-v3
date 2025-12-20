#!/bin/bash

# Level 2: Istio Gateway Routing Test
# Istio Gateway를 통한 라우팅 정확성을 검증합니다

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

echo "=== Istio Gateway Routing Test ==="

# Get Ingress Gateway endpoint
INGRESS_HOST=$(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -z "$INGRESS_HOST" ]; then
    # Try NodePort
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    NODE_PORT=$(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
    INGRESS_HOST="${NODE_IP}:${NODE_PORT}"
fi

echo "Ingress Gateway: ${INGRESS_HOST}"

# Test routing via Ingress Gateway
test_routing() {
    local path=$1
    local expected_status=$2
    local description=$3
    local method=${4:-GET}

    local status=$(kubectl run test-curl-$$-$RANDOM --rm -i --restart=Never --image=curlimages/curl --quiet -- \
        curl -s -o /dev/null -w "%{http_code}" -X "${method}" "http://${INGRESS_HOST}${path}" 2>/dev/null || echo "000")

    if [ "$status" == "$expected_status" ]; then
        log_success "${description}: HTTP ${status}"
        return 0
    else
        log_error "${description}: Expected ${expected_status}, Got ${status}"
        return 1
    fi
}

# Test 1: Blog UI (/)
echo "Test: Blog UI Routing (/)"
test_routing "/" "200" "Root path -> Blog Service"

# Test 2: Blog UI (/blog/)
echo "Test: Blog UI Routing (/blog/)"
test_routing "/blog/" "200" "/blog/ -> Blog Service"

# Test 3: Blog API (/blog/api/posts)
echo "Test: Blog API Routing"
test_routing "/blog/api/posts" "200" "/blog/api/posts -> Blog Service"

# Test 4: Login Endpoint (/api/login)
echo "Test: Login Routing"
# 422 expected for POST request without body (validates routing to auth-service)
test_routing "/api/login" "422" "/api/login -> Auth Service" "POST"

# Exit with appropriate code
if [ $FAILED -eq 1 ]; then
    echo ""
    echo "Istio Gateway Routing Test: FAILED"
    exit 1
else
    echo ""
    echo "Istio Gateway Routing Test: PASSED"
    exit 0
fi
