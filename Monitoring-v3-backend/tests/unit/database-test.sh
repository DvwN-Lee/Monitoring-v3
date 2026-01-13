#!/bin/bash

# Level 3: Database/Cache Connection Test
# PostgreSQL과 Redis 연결을 검증합니다

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

echo "=== Database/Cache Connection Test ==="

# Test 1: PostgreSQL Connection
echo "Test: PostgreSQL Connection"
POSTGRES_POD=$(kubectl get pods -n titanium-prod -l app=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POSTGRES_POD" ]; then
    if kubectl exec -n titanium-prod "$POSTGRES_POD" -- psql -U postgres -d titanium -c "SELECT 1" &> /dev/null; then
        log_success "PostgreSQL connection successful"
    else
        log_error "PostgreSQL connection failed"
    fi
else
    log_error "PostgreSQL pod not found"
fi

# Test 2: PostgreSQL Tables
echo "Test: PostgreSQL Tables"
if [ -n "$POSTGRES_POD" ]; then
    TABLES=$(kubectl exec -n titanium-prod "$POSTGRES_POD" -- psql -U postgres -d titanium -t -c "\dt" 2>/dev/null | grep -c "public" || echo "0")
    if [ "$TABLES" -gt 0 ]; then
        log_success "PostgreSQL has ${TABLES} tables"
    else
        log_error "PostgreSQL has no tables"
    fi
fi

# Test 3: Redis Connection
echo "Test: Redis Connection"
REDIS_POD=$(kubectl get pods -n titanium-prod -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$REDIS_POD" ]; then
    PONG=$(kubectl exec -n titanium-prod "$REDIS_POD" -- redis-cli PING 2>/dev/null || echo "FAIL")
    if [ "$PONG" == "PONG" ]; then
        log_success "Redis PING: PONG"
    else
        log_error "Redis PING failed: ${PONG}"
    fi
else
    log_error "Redis pod not found"
fi

# Exit with appropriate code
if [ $FAILED -eq 1 ]; then
    echo ""
    echo "Database/Cache Connection Test: FAILED"
    exit 1
else
    echo ""
    echo "Database/Cache Connection Test: PASSED"
    exit 0
fi
