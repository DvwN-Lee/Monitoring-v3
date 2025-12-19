#!/bin/bash

# Level 4: Monitoring Stack Test
# Prometheus, Grafana, Loki 모니터링 스택을 검증합니다

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

echo "=== Monitoring Stack Test ==="

# Test 1: Prometheus Pod
echo "Test: Prometheus Pod"
if kubectl get pods -n istio-system -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q "Running"; then
    log_success "Prometheus pod is Running"
else
    log_error "Prometheus pod is not Running"
fi

# Test 2: Prometheus API
echo "Test: Prometheus API"
PROM_POD=$(kubectl get pods -n istio-system -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$PROM_POD" ]; then
    if kubectl exec -n istio-system "$PROM_POD" -- wget -qO- http://localhost:9090/api/v1/status/config 2>/dev/null | grep -q "status"; then
        log_success "Prometheus API is responding"
    else
        log_error "Prometheus API is not responding"
    fi
else
    log_error "Prometheus pod not found for API test"
fi

# Test 3: Grafana Pod
echo "Test: Grafana Pod"
if kubectl get pods -n istio-system -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -q "Running"; then
    log_success "Grafana pod is Running"
else
    log_error "Grafana pod is not Running"
fi



# Exit with appropriate code
if [ $FAILED -eq 1 ]; then
    echo ""
    echo "Monitoring Stack Test: FAILED"
    exit 1
else
    echo ""
    echo "Monitoring Stack Test: PASSED"
    exit 0
fi
