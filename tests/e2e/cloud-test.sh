#!/bin/bash

# E2E Cloud Environment Test Script
# GitHub Actions에서 실행되며, 외부에서 클러스터 서비스를 테스트합니다.
# Blog Service CRUD 및 모니터링 대시보드 API를 검증합니다.

set -euo pipefail

# Configuration
CLUSTER_IP="${CLUSTER_IP:-34.47.68.205}"
ISTIO_HTTP_PORT="${ISTIO_HTTP_PORT:-31080}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-31090}"
GRAFANA_PORT="${GRAFANA_PORT:-31300}"
KIALI_PORT="${KIALI_PORT:-20001}"

BASE_URL="http://${CLUSTER_IP}:${ISTIO_HTTP_PORT}"
PROMETHEUS_URL="http://${CLUSTER_IP}:${PROMETHEUS_PORT}"
GRAFANA_URL="http://${CLUSTER_IP}:${GRAFANA_PORT}"
KIALI_URL="http://${CLUSTER_IP}:${KIALI_PORT}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
PASSED=0
FAILED=0
TOTAL=0

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED++))
    ((TOTAL++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED++))
    ((TOTAL++))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# HTTP request helper
http_test() {
    local method=$1
    local url=$2
    local expected_status=$3
    local description=$4
    local data=${5:-}
    local headers=${6:-}

    local curl_opts="-s -o /tmp/response.txt -w %{http_code} --connect-timeout 10 --max-time 30"

    if [ -n "$data" ]; then
        curl_opts="$curl_opts -d '$data' -H 'Content-Type: application/json'"
    fi

    if [ -n "$headers" ]; then
        curl_opts="$curl_opts $headers"
    fi

    local status
    status=$(eval "curl $curl_opts -X $method '$url'" 2>/dev/null || echo "000")

    if [ "$status" == "$expected_status" ]; then
        log_success "$description: HTTP $status"
        return 0
    else
        log_error "$description: Expected $expected_status, Got $status"
        if [ -f /tmp/response.txt ]; then
            echo "  Response: $(head -c 200 /tmp/response.txt)"
        fi
        return 1
    fi
}

# JSON response validator
validate_json_field() {
    local file=$1
    local field=$2
    local expected=$3
    local description=$4

    if [ ! -f "$file" ]; then
        log_error "$description: Response file not found"
        return 1
    fi

    local value
    value=$(jq -r "$field" "$file" 2>/dev/null || echo "")

    if [ "$value" == "$expected" ]; then
        log_success "$description: $field = $expected"
        return 0
    else
        log_error "$description: Expected $field = $expected, Got $value"
        return 1
    fi
}

# Test: Health Check
test_health_check() {
    echo ""
    echo "=== Health Check Tests ==="

    # Blog Service Health via Istio Gateway
    http_test "GET" "${BASE_URL}/blog/health" "200" "Blog Service Health Check"

    # Blog Service Metrics
    http_test "GET" "${BASE_URL}/blog/metrics" "200" "Blog Service Metrics"

    # Prometheus Health
    http_test "GET" "${PROMETHEUS_URL}/-/healthy" "200" "Prometheus Health"

    # Grafana Health
    http_test "GET" "${GRAFANA_URL}/api/health" "200" "Grafana Health"
}

# Test: Blog Read API
test_blog_read_api() {
    echo ""
    echo "=== Blog Read API Tests ==="

    # Get Posts List
    http_test "GET" "${BASE_URL}/blog/api/posts" "200" "Blog Posts List"

    # Get Categories
    http_test "GET" "${BASE_URL}/blog/api/categories" "200" "Blog Categories List"

    # Get Blog Web UI
    http_test "GET" "${BASE_URL}/blog/" "200" "Blog Web UI"
}

# Test: Blog CRUD Operations
test_blog_crud() {
    echo ""
    echo "=== Blog CRUD Tests ==="

    # Create Post
    local create_data='{"title":"E2E Test Post","content":"This is an automated test post","category":"test"}'

    local create_status
    create_status=$(curl -s -o /tmp/create_response.txt -w "%{http_code}" \
        -X POST "${BASE_URL}/blog/api/posts" \
        -H "Content-Type: application/json" \
        -d "$create_data" \
        --connect-timeout 10 --max-time 30 2>/dev/null || echo "000")

    if [ "$create_status" == "201" ] || [ "$create_status" == "200" ]; then
        log_success "Blog Post Create: HTTP $create_status"

        # Extract post ID from response
        local post_id
        post_id=$(jq -r '.id // .post_id // empty' /tmp/create_response.txt 2>/dev/null || echo "")

        if [ -n "$post_id" ] && [ "$post_id" != "null" ]; then
            log_info "Created post ID: $post_id"

            # Update Post
            local update_data='{"title":"E2E Test Post Updated","content":"This is an updated test post"}'
            http_test "PATCH" "${BASE_URL}/blog/api/posts/${post_id}" "200" "Blog Post Update" "$update_data"

            # Delete Post
            http_test "DELETE" "${BASE_URL}/blog/api/posts/${post_id}" "200" "Blog Post Delete"
        else
            log_warn "Could not extract post ID, skipping update/delete tests"
            ((TOTAL+=2))
        fi
    else
        log_error "Blog Post Create: Expected 201 or 200, Got $create_status"
        log_warn "Skipping update/delete tests due to create failure"
        ((TOTAL+=2))
    fi
}

# Test: Prometheus API
test_prometheus_api() {
    echo ""
    echo "=== Prometheus API Tests ==="

    # Targets API
    http_test "GET" "${PROMETHEUS_URL}/api/v1/targets" "200" "Prometheus Targets API"

    # Query API - up metric
    http_test "GET" "${PROMETHEUS_URL}/api/v1/query?query=up" "200" "Prometheus Query API (up metric)"

    # Service Discovery
    http_test "GET" "${PROMETHEUS_URL}/api/v1/label/__name__/values" "200" "Prometheus Label Values API"
}

# Test: Grafana API
test_grafana_api() {
    echo ""
    echo "=== Grafana API Tests ==="

    # Health API
    local health_status
    health_status=$(curl -s -o /tmp/grafana_health.txt -w "%{http_code}" \
        "${GRAFANA_URL}/api/health" \
        --connect-timeout 10 --max-time 30 2>/dev/null || echo "000")

    if [ "$health_status" == "200" ]; then
        log_success "Grafana Health API: HTTP $health_status"

        # Validate database status
        local db_status
        db_status=$(jq -r '.database' /tmp/grafana_health.txt 2>/dev/null || echo "")
        if [ "$db_status" == "ok" ]; then
            log_success "Grafana Database Status: ok"
        else
            log_error "Grafana Database Status: Expected ok, Got $db_status"
        fi
    else
        log_error "Grafana Health API: Expected 200, Got $health_status"
        ((TOTAL++))
    fi

    # Datasources API (anonymous access test)
    http_test "GET" "${GRAFANA_URL}/api/datasources" "401" "Grafana Datasources (expects auth required)"

    # Frontend Settings (public)
    http_test "GET" "${GRAFANA_URL}/api/frontend/settings" "200" "Grafana Frontend Settings"
}

# Test: Kiali API
test_kiali_api() {
    echo ""
    echo "=== Kiali API Tests ==="

    # Status API
    http_test "GET" "${KIALI_URL}/api/status" "200" "Kiali Status API"

    # Namespaces API
    http_test "GET" "${KIALI_URL}/api/namespaces" "200" "Kiali Namespaces API"

    # Istio Config API
    http_test "GET" "${KIALI_URL}/api/istio/config" "200" "Kiali Istio Config API"
}

# Test: Service Connectivity
test_service_connectivity() {
    echo ""
    echo "=== Service Connectivity Tests ==="

    # Test each service port
    local services=(
        "Istio Gateway:${CLUSTER_IP}:${ISTIO_HTTP_PORT}"
        "Prometheus:${CLUSTER_IP}:${PROMETHEUS_PORT}"
        "Grafana:${CLUSTER_IP}:${GRAFANA_PORT}"
        "Kiali:${CLUSTER_IP}:${KIALI_PORT}"
    )

    for service in "${services[@]}"; do
        local name="${service%%:*}"
        local host_port="${service#*:}"
        local host="${host_port%:*}"
        local port="${host_port##*:}"

        if nc -z -w5 "$host" "$port" 2>/dev/null; then
            log_success "$name Port $port: Reachable"
        else
            log_error "$name Port $port: Unreachable"
        fi
    done
}

# Print summary
print_summary() {
    echo ""
    echo "========================================"
    echo "         E2E TEST SUMMARY"
    echo "========================================"
    echo ""
    echo "Cluster IP: ${CLUSTER_IP}"
    echo "Total Tests: ${TOTAL}"
    echo -e "Passed: ${GREEN}${PASSED}${NC}"
    echo -e "Failed: ${RED}${FAILED}${NC}"
    echo ""

    if [ $FAILED -gt 0 ]; then
        echo -e "${RED}E2E TEST RESULT: FAILED${NC}"
        return 1
    else
        echo -e "${GREEN}E2E TEST RESULT: PASSED${NC}"
        return 0
    fi
}

# Main execution
main() {
    echo "========================================"
    echo "    E2E Cloud Environment Tests"
    echo "========================================"
    echo ""
    log_info "Starting E2E tests against cluster: ${CLUSTER_IP}"
    log_info "Test started at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    # Run all tests
    test_service_connectivity
    test_health_check
    test_blog_read_api
    test_blog_crud
    test_prometheus_api
    test_grafana_api
    test_kiali_api

    # Print summary and exit
    print_summary
}

# Execute main function
main "$@"
