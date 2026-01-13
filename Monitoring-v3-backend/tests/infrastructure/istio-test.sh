#!/bin/bash

# Level 4: Istio Resources Test
# Istio Service Mesh 리소스 상태를 검증합니다

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

echo "=== Istio Resources Test ==="

# Test 1: Istio Ingress Gateway
echo "Test: Istio Ingress Gateway"
if kubectl get svc -n istio-system istio-ingressgateway --no-headers 2>/dev/null | grep -q "ingress"; then
    GATEWAY_IP=$(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "NodePort")
    log_success "Istio Ingress Gateway exists (IP/Type: ${GATEWAY_IP})"
else
    log_error "Istio Ingress Gateway not found"
fi

# Test 2: Gateway Resource
echo "Test: Gateway Resource"
if kubectl get gateway -n titanium-prod prod-titanium-gateway &> /dev/null; then
    log_success "Gateway 'prod-titanium-gateway' exists"
else
    log_error "Gateway 'prod-titanium-gateway' not found"
fi

# Test 3: VirtualService
echo "Test: VirtualService"
if kubectl get virtualservice -n titanium-prod prod-titanium-vs &> /dev/null; then
    log_success "VirtualService 'prod-titanium-vs' exists"
else
    log_error "VirtualService 'prod-titanium-vs' not found"
fi

# Test 4: DestinationRule
echo "Test: DestinationRule"
DR_COUNT=$(kubectl get destinationrule -n titanium-prod --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$DR_COUNT" -gt 0 ]; then
    log_success "${DR_COUNT} DestinationRules configured"
else
    log_error "No DestinationRules found"
fi

# Test 5: PeerAuthentication
echo "Test: PeerAuthentication"
if kubectl get peerauthentication -n titanium-prod --no-headers 2>/dev/null | grep -q "STRICT"; then
    log_success "PeerAuthentication mode: STRICT"
else
    log_error "PeerAuthentication not in STRICT mode"
fi

# Exit with appropriate code
if [ $FAILED -eq 1 ]; then
    echo ""
    echo "Istio Resources Test: FAILED"
    exit 1
else
    echo ""
    echo "Istio Resources Test: PASSED"
    exit 0
fi
