#!/bin/bash
# get-kubeconfig.sh - k3s Bootstrap 완료 대기 후 kubeconfig 자동 설정
# 사용법: ./scripts/get-kubeconfig.sh [--timeout SECONDS]

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 로깅 함수
log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING:${NC} $*"
}

error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ERROR:${NC} $*"
}

# 기본 설정
TIMEOUT=${TIMEOUT:-600}  # 기본 10분
POLL_INTERVAL=10
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config-gcp}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/titanium-key}"

# 인자 파싱
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --output)
            KUBECONFIG_PATH="$2"
            shift 2
            ;;
        --ssh-key)
            SSH_KEY="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --timeout SECONDS   Bootstrap 완료 대기 시간 (default: 600)"
            echo "  --output PATH       kubeconfig 저장 경로 (default: ~/.kube/config-gcp)"
            echo "  --ssh-key PATH      SSH private key 경로 (default: ~/.ssh/titanium-key)"
            echo "  --help              도움말 표시"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# SSH 키 파일 확인
if [[ ! -f "$SSH_KEY" ]]; then
    error "SSH key not found: $SSH_KEY"
    error "Specify with --ssh-key or set SSH_KEY environment variable"
    exit 1
fi
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes -i $SSH_KEY"

# Terraform 디렉토리 확인
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"

# Terraform output에서 정보 추출
log "Terraform output에서 Master 정보 추출 중..."
cd "$TF_DIR"

# terraform output 명령어로 state 존재 여부 확인
MASTER_IP=$(terraform output -raw master_external_ip 2>/dev/null)
if [[ -z "$MASTER_IP" || "$MASTER_IP" == *"No outputs found"* || "$MASTER_IP" == *"error"* ]]; then
    error "master_external_ip를 가져올 수 없습니다."
    error "Run 'terraform apply' first."
    exit 1
fi

log "Master IP: $MASTER_IP"

# SSH 연결 테스트
log "SSH 연결 테스트 중..."
if ! ssh $SSH_OPTS ubuntu@"$MASTER_IP" "echo ok" &>/dev/null; then
    error "SSH 연결 실패. VM이 준비되지 않았거나 SSH key가 올바르지 않습니다."
    error "SSH key: $SSH_KEY"
    exit 1
fi
log "SSH 연결 성공"

# Bootstrap 완료 대기
log "k3s Bootstrap 완료 대기 중... (최대 ${TIMEOUT}초)"
ELAPSED=0
BOOTSTRAP_COMPLETE=false

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    # Bootstrap 상태 확인
    STATUS=$(ssh $SSH_OPTS ubuntu@"$MASTER_IP" "cat /tmp/k3s-status 2>/dev/null || echo 'pending'" 2>/dev/null)

    if [[ "$STATUS" == "bootstrap-complete" ]]; then
        BOOTSTRAP_COMPLETE=true
        break
    fi

    # k3s 설치 상태 확인 (fallback)
    if ssh $SSH_OPTS ubuntu@"$MASTER_IP" "sudo kubectl get nodes &>/dev/null" 2>/dev/null; then
        # k3s가 작동하면 bootstrap-complete 마커가 없어도 진행
        if [[ $ELAPSED -gt 120 ]]; then
            warn "Bootstrap 마커 없음, k3s 작동 확인됨. 진행합니다."
            BOOTSTRAP_COMPLETE=true
            break
        fi
    fi

    printf "\r  대기 중... %d/%d초 (상태: %s)    " "$ELAPSED" "$TIMEOUT" "$STATUS"
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""  # 줄바꿈

if [[ "$BOOTSTRAP_COMPLETE" != "true" ]]; then
    error "Bootstrap 시간 초과 (${TIMEOUT}초)"
    error "수동으로 확인하세요: ssh -i $SSH_KEY ubuntu@$MASTER_IP 'tail -f /var/log/k3s-bootstrap.log'"
    exit 1
fi

log "Bootstrap 완료!"

# kubeconfig 가져오기
log "kubeconfig 가져오는 중..."
mkdir -p "$(dirname "$KUBECONFIG_PATH")"

ssh $SSH_OPTS ubuntu@"$MASTER_IP" "sudo cat /etc/rancher/k3s/k3s.yaml" 2>/dev/null | \
    sed "s/127.0.0.1/$MASTER_IP/g" > "$KUBECONFIG_PATH"

if [[ ! -s "$KUBECONFIG_PATH" ]]; then
    error "kubeconfig 파일이 비어 있습니다."
    exit 1
fi

chmod 600 "$KUBECONFIG_PATH"
log "kubeconfig 저장됨: $KUBECONFIG_PATH"

# 연결 테스트
log "Cluster 연결 테스트 중..."
if KUBECONFIG="$KUBECONFIG_PATH" kubectl get nodes &>/dev/null; then
    log "Cluster 연결 성공!"
    echo ""
    KUBECONFIG="$KUBECONFIG_PATH" kubectl get nodes
    echo ""
    log "사용 방법:"
    echo "  export KUBECONFIG=$KUBECONFIG_PATH"
    echo "  kubectl get pods -A"
else
    warn "Cluster 연결 실패. k3s가 아직 초기화 중일 수 있습니다."
    warn "잠시 후 다시 시도하세요: KUBECONFIG=$KUBECONFIG_PATH kubectl get nodes"
fi

log "완료!"
