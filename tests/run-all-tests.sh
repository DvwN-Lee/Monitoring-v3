#!/bin/bash

# Top-Down 전체 서비스 테스트 오케스트레이션 스크립트
# 실행 순서: Level 4 (Infrastructure) → Level 3 (Services) → Level 2 (Integration) → Level 1 (E2E)

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test result counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Level counters
# Level counters
LEVEL4_PASSED=0
LEVEL4_FAILED=0
LEVEL3_PASSED=0
LEVEL3_FAILED=0
LEVEL2_PASSED=0
LEVEL2_FAILED=0
LEVEL1_PASSED=0
LEVEL1_FAILED=0

# Test details array
TEST_DETAILS=()

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_FILE="${SCRIPT_DIR}/test-results.json"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED_TESTS++))
    ((TOTAL_TESTS++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED_TESTS++))
    ((TOTAL_TESTS++))
}

log_section() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}$1${NC}"
    echo -e "${YELLOW}========================================${NC}"
}

# Add test result to details
add_test_result() {
    local level=$1
    local test_name=$2
    local status=$3
    local message=$4

    TEST_DETAILS+=("{\"level\":\"${level}\",\"test\":\"${test_name}\",\"status\":\"${status}\",\"message\":\"${message}\"}")

    if [ "$status" == "PASS" ]; then
        case $level in
            "level4") ((LEVEL4_PASSED++)) ;;
            "level3") ((LEVEL3_PASSED++)) ;;
            "level2") ((LEVEL2_PASSED++)) ;;
            "level1") ((LEVEL1_PASSED++)) ;;
        esac
    else
        case $level in
            "level4") ((LEVEL4_FAILED++)) ;;
            "level3") ((LEVEL3_FAILED++)) ;;
            "level2") ((LEVEL2_FAILED++)) ;;
            "level1") ((LEVEL1_FAILED++)) ;;
        esac
    fi
}

# Run test script
run_test_script() {
    local script=$1
    local test_name=$2
    local level=$3

    if [ ! -f "$script" ]; then
        log_error "${test_name}: Script not found"
        add_test_result "$level" "$test_name" "FAIL" "Script not found: $script"
        return 1
    fi

    if bash "$script"; then
        log_success "${test_name}"
        add_test_result "$level" "$test_name" "PASS" "Test passed"
        return 0
    else
        log_error "${test_name}"
        add_test_result "$level" "$test_name" "FAIL" "Test failed"
        return 1
    fi
}

# Generate JSON report
generate_json_report() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local pass_rate=0
    if [ $TOTAL_TESTS -gt 0 ]; then
        pass_rate=$(awk "BEGIN {printf \"%.1f\", ($PASSED_TESTS/$TOTAL_TESTS)*100}")
    fi

    # Convert test details array to JSON array
    local details_json="["
    local first=true
    for detail in "${TEST_DETAILS[@]}"; do
        if [ "$first" = true ]; then
            details_json+="$detail"
            first=false
        else
            details_json+=",$detail"
        fi
    done
    details_json+="]"

    cat > "$RESULT_FILE" << EOF
{
  "timestamp": "${timestamp}",
  "summary": {
    "total": ${TOTAL_TESTS},
    "passed": ${PASSED_TESTS},
    "failed": ${FAILED_TESTS},
    "pass_rate": "${pass_rate}%"
  },
  "levels": {
    "level4_infrastructure": {
      "passed": ${LEVEL4_PASSED},
      "failed": ${LEVEL4_FAILED}
    },
    "level3_services": {
      "passed": ${LEVEL3_PASSED},
      "failed": ${LEVEL3_FAILED}
    },
    "level2_integration": {
      "passed": ${LEVEL2_PASSED},
      "failed": ${LEVEL2_FAILED}
    },
    "level1_e2e": {
      "passed": ${LEVEL1_PASSED},
      "failed": ${LEVEL1_FAILED}
    }
  },
  "details": ${details_json}
}
EOF

    log_info "Test results saved to: ${RESULT_FILE}"
}

# Main test execution
main() {
    log_section "Top-Down 전체 서비스 테스트 시작"
    log_info "실행 순서: Level 4 → Level 3 → Level 2 → Level 1"

    # Level 4: Infrastructure Tests
    log_section "Level 4: Infrastructure Tests"
    run_test_script "${SCRIPT_DIR}/infrastructure/k8s-test.sh" "Kubernetes Resources" "level4" || true
    run_test_script "${SCRIPT_DIR}/infrastructure/istio-test.sh" "Istio Resources" "level4" || true
    run_test_script "${SCRIPT_DIR}/infrastructure/monitoring-test.sh" "Monitoring Stack" "level4" || true
    run_test_script "${SCRIPT_DIR}/infrastructure/gitops-test.sh" "GitOps (Argo CD)" "level4" || true

    # Check Level 4 pass rate
    local level4_total=$((LEVEL4_PASSED + LEVEL4_FAILED))
    local level4_rate=0
    if [ $level4_total -gt 0 ]; then
        level4_rate=$(awk "BEGIN {printf \"%.0f\", ($LEVEL4_PASSED/$level4_total)*100}")
    fi

    if [ $level4_rate -lt 100 ]; then
        log_error "Level 4 failed (${level4_rate}% pass rate). Required: 100%"
        log_info "Stopping tests due to infrastructure failure"
        generate_json_report
        exit 1
    fi

    # Level 3: Individual Service Tests
    log_section "Level 3: Individual Service Tests"
    run_test_script "${SCRIPT_DIR}/unit/api-gateway-test.sh" "API Gateway" "level3" || true
    run_test_script "${SCRIPT_DIR}/unit/auth-service-test.sh" "Auth Service" "level3" || true
    run_test_script "${SCRIPT_DIR}/unit/user-service-test.sh" "User Service" "level3" || true
    run_test_script "${SCRIPT_DIR}/unit/blog-service-test.sh" "Blog Service" "level3" || true
    run_test_script "${SCRIPT_DIR}/unit/database-test.sh" "Database/Cache" "level3" || true

    # Level 2: Integration Tests
    log_section "Level 2: Integration Tests"
    run_test_script "${SCRIPT_DIR}/integration/routing-test.sh" "Istio Routing" "level2" || true
    run_test_script "${SCRIPT_DIR}/integration/mtls-test.sh" "mTLS Verification" "level2" || true

    # Level 1: E2E Tests (k6)
    log_section "Level 1: E2E Tests"
    if command -v k6 &> /dev/null; then
        if k6 run "${SCRIPT_DIR}/e2e/e2e-test.js" --quiet; then
            log_success "E2E User Journey"
            add_test_result "level1" "E2E User Journey" "PASS" "All scenarios passed"
        else
            log_error "E2E User Journey"
            add_test_result "level1" "E2E User Journey" "FAIL" "One or more scenarios failed"
        fi
    else
        log_error "E2E User Journey: k6 not installed"
        add_test_result "level1" "E2E User Journey" "FAIL" "k6 not installed"
    fi

    # Generate final report
    log_section "테스트 결과 요약"
    echo ""
    echo "Total Tests: ${TOTAL_TESTS}"
    echo -e "Passed: ${GREEN}${PASSED_TESTS}${NC}"
    echo -e "Failed: ${RED}${FAILED_TESTS}${NC}"
    echo ""
    echo "Level 4 (Infrastructure): ${LEVEL4_PASSED} passed, ${LEVEL4_FAILED} failed"
    echo "Level 3 (Services): ${LEVEL3_PASSED} passed, ${LEVEL3_FAILED} failed"
    echo "Level 2 (Integration): ${LEVEL2_PASSED} passed, ${LEVEL2_FAILED} failed"
    echo "Level 1 (E2E): ${LEVEL1_PASSED} passed, ${LEVEL1_FAILED} failed"
    echo ""

    generate_json_report

    if [ $FAILED_TESTS -gt 0 ]; then
        log_error "테스트 실패: ${FAILED_TESTS}개 테스트 실패"
        exit 1
    else
        log_success "모든 테스트 통과!"
        exit 0
    fi
}

main "$@"
