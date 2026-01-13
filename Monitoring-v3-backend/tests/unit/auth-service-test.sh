#!/bin/bash

# Level 3: Auth Service Test
# Auth Service 개별 Endpoint를 검증합니다

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

# Test service endpoint via localhost (validates service health directly)
test_endpoint() {
    local deployment=$1
    local port=$2
    local endpoint=$3
    local expected_status=$4
    local description=$5

    # Test via localhost using istio-proxy sidecar curl
    local status=$(kubectl exec -n titanium-prod deploy/${deployment} -c istio-proxy -- \
        curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}${endpoint}" 2>/dev/null || echo "000")

    if [ "$status" == "$expected_status" ]; then
        log_success "${description}: HTTP ${status}"
        return 0
    else
        log_error "${description}: Expected ${expected_status}, Got ${status}"
        return 1
    fi
}

echo "=== Auth Service Test ==="

# Test 1: Health Check
echo "Test: Health Check"
test_endpoint "prod-auth-service-deployment" "8002" "/health" "200" "Health endpoint"

# Test 2: Metrics
echo "Test: Metrics"
test_endpoint "prod-auth-service-deployment" "8002" "/metrics" "200" "Metrics endpoint"

# Test 3: Stats
echo "Test: Stats"
test_endpoint "prod-auth-service-deployment" "8002" "/stats" "200" "Stats endpoint"

# Test 4: Login endpoint exists (returns 405 for GET - POST required)
echo "Test: Login Endpoint"
test_endpoint "prod-auth-service-deployment" "8002" "/login" "405" "Login endpoint (POST required)"

# Exit with appropriate code
if [ $FAILED -eq 1 ]; then
    echo ""
    echo "Auth Service Test: FAILED"
    exit 1
else
    echo ""
    echo "Auth Service Test: PASSED"
    exit 0
fi
