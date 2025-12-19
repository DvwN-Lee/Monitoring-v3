#!/bin/bash

# Level 4: GitOps (Argo CD) Test
# Argo CD GitOps 상태를 검증합니다

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

echo "=== GitOps (Argo CD) Test ==="

# Test 1: Argo CD Pods
echo "Test: Argo CD Pods"
if kubectl get pods -n argocd --no-headers 2>/dev/null | grep -qv "Running"; then
    log_error "Some Argo CD pods are not Running"
else
    POD_COUNT=$(kubectl get pods -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')
    log_success "All ${POD_COUNT} Argo CD pods are Running"
fi

# Test 2: Application Status (Health)
echo "Test: Application Health"
APP_HEALTH=$(kubectl get application -n argocd titanium-solid-cloud -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
if [ "$APP_HEALTH" == "Healthy" ]; then
    log_success "Application 'titanium-solid-cloud' is Healthy"
else
    log_error "Application 'titanium-solid-cloud' health status: ${APP_HEALTH}"
fi

# Test 3: Application Sync Status
echo "Test: Application Sync Status"
APP_SYNC=$(kubectl get application -n argocd titanium-solid-cloud -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
if [ "$APP_SYNC" == "Synced" ]; then
    log_success "Application 'titanium-solid-cloud' is Synced"
else
    log_error "Application 'titanium-solid-cloud' sync status: ${APP_SYNC}"
fi

# Test 4: Source Repository
echo "Test: Source Repository"
REPO_URL=$(kubectl get application -n argocd titanium-solid-cloud -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || echo "Unknown")
if [[ "$REPO_URL" == *"Monitoring-v2"* ]]; then
    log_success "Tracking correct repository"
else
    log_error "Repository URL unexpected: ${REPO_URL}"
fi

# Test 5: Auto Sync Policy
echo "Test: Auto Sync Policy"
AUTO_SYNC=$(kubectl get application -n argocd titanium-solid-cloud -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null)
if [ -n "$AUTO_SYNC" ]; then
    log_success "Auto sync is enabled"
else
    echo -e "${NC}[WARN] Auto sync is not enabled"
fi

# Exit with appropriate code
if [ $FAILED -eq 1 ]; then
    echo ""
    echo "GitOps (Argo CD) Test: FAILED"
    exit 1
else
    echo ""
    echo "GitOps (Argo CD) Test: PASSED"
    exit 0
fi
