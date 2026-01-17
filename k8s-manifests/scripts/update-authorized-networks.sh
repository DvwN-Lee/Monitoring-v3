#!/bin/bash
set -e

# GKE Master Authorized Networks IP 자동 업데이트 스크립트
# 현재 공인 IP를 감지하여 Authorized Networks에 추가합니다.

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 설정 (환경 변수로 Override 가능)
CLUSTER_NAME="${GKE_CLUSTER_NAME:-staging-exam-cluster}"
REGION="${GKE_REGION:-asia-northeast3}"
ZONE="${GKE_ZONE:-}"
PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"

# Location 플래그 결정 (Zone 우선, 없으면 Region 사용)
get_location_flag() {
    if [ -n "$ZONE" ]; then
        echo "--zone=$ZONE"
    else
        echo "--region=$REGION"
    fi
}

# 필수 도구 확인
check_prerequisites() {
    log_info "필수 도구 확인 중..."

    if ! command -v gcloud &>/dev/null; then
        log_error "gcloud CLI가 설치되어 있지 않습니다."
        exit 1
    fi

    if ! command -v curl &>/dev/null; then
        log_error "curl이 설치되어 있지 않습니다."
        exit 1
    fi

    if [ -z "$PROJECT" ]; then
        log_error "GCP Project가 설정되지 않았습니다. GCP_PROJECT 환경 변수를 설정하거나 gcloud config set project를 실행하세요."
        exit 1
    fi

    log_info "Project: $PROJECT"
    log_info "Cluster: $CLUSTER_NAME"
    if [ -n "$ZONE" ]; then
        log_info "Zone: $ZONE"
    else
        log_info "Region: $REGION"
    fi
}

# 현재 IP 감지
get_current_ip() {
    log_info "현재 공인 IP 감지 중..."

    CURRENT_IP=$(curl -s --connect-timeout 5 https://api.ipify.org || \
                 curl -s --connect-timeout 5 https://ifconfig.me || \
                 curl -s --connect-timeout 5 https://icanhazip.com)

    if [ -z "$CURRENT_IP" ]; then
        log_error "공인 IP를 감지할 수 없습니다."
        exit 1
    fi

    CURRENT_CIDR="${CURRENT_IP}/32"
    log_info "현재 IP: $CURRENT_IP"
}

# 기존 Authorized Networks 조회
get_existing_networks() {
    log_info "기존 Authorized Networks 조회 중..."

    # Cluster 존재 여부 확인
    if ! gcloud container clusters describe "$CLUSTER_NAME" \
        $(get_location_flag) --project="$PROJECT" &>/dev/null; then
        log_error "Cluster '$CLUSTER_NAME'을 찾을 수 없습니다."
        exit 1
    fi

    # 기존 CIDR 목록 조회 (세미콜론 및 개행을 쉼표로 변환)
    EXISTING_CIDRS=$(gcloud container clusters describe "$CLUSTER_NAME" \
        $(get_location_flag) --project="$PROJECT" \
        --format='value(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock)' \
        2>/dev/null | tr ';\n' ',' | sed 's/,$//' | sed 's/^,//')

    if [ -n "$EXISTING_CIDRS" ]; then
        log_info "기존 허용 IP 목록: $EXISTING_CIDRS"
    else
        log_warn "기존 허용 IP 목록이 비어 있습니다."
        EXISTING_CIDRS=""
    fi
}

# 현재 IP가 이미 허용 목록에 있는지 확인
check_ip_exists() {
    if [[ "$EXISTING_CIDRS" == *"$CURRENT_IP"* ]]; then
        log_info "현재 IP($CURRENT_IP)가 이미 허용 목록에 있습니다."
        return 0
    fi
    return 1
}

# Authorized Networks 업데이트
update_networks() {
    log_info "Authorized Networks 업데이트 중..."

    # 새로운 CIDR 목록 생성
    if [ -n "$EXISTING_CIDRS" ]; then
        NEW_CIDRS="${EXISTING_CIDRS},${CURRENT_CIDR}"
    else
        NEW_CIDRS="${CURRENT_CIDR}"
    fi

    log_info "새로운 허용 IP 목록: $NEW_CIDRS"

    # 업데이트 실행
    gcloud container clusters update "$CLUSTER_NAME" \
        $(get_location_flag) --project="$PROJECT" \
        --enable-master-authorized-networks \
        --master-authorized-networks="$NEW_CIDRS"

    log_info "Authorized Networks 업데이트 완료"
}

# Cluster 접근 검증
verify_access() {
    log_info "Cluster 접근 검증 중..."

    # kubeconfig 업데이트
    gcloud container clusters get-credentials "$CLUSTER_NAME" \
        $(get_location_flag) --project="$PROJECT"

    # 연결 테스트
    if kubectl cluster-info &>/dev/null; then
        log_info "Cluster 접근 성공"
        kubectl cluster-info
    else
        log_warn "Cluster 접근 실패. 잠시 후 다시 시도하세요. (변경 사항 반영에 시간이 걸릴 수 있습니다)"
    fi
}

# 도움말 출력
show_help() {
    echo "사용법: $0 [OPTIONS]"
    echo ""
    echo "GKE Master Authorized Networks에 현재 IP를 추가합니다."
    echo ""
    echo "환경 변수:"
    echo "  GKE_CLUSTER_NAME  Cluster 이름 (기본값: staging-exam-cluster)"
    echo "  GKE_REGION        Cluster Region (기본값: asia-northeast3)"
    echo "  GKE_ZONE          Cluster Zone (설정 시 Region보다 우선)"
    echo "  GCP_PROJECT       GCP Project ID"
    echo ""
    echo "옵션:"
    echo "  -h, --help        도움말 출력"
    echo "  --dry-run         실제 업데이트 없이 변경 사항만 출력"
    echo ""
    echo "예시:"
    echo "  $0"
    echo "  GKE_CLUSTER_NAME=my-cluster GKE_REGION=us-central1 $0"
}

# 메인 실행
main() {
    # 옵션 파싱
    DRY_RUN=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                log_error "알 수 없는 옵션: $1"
                show_help
                exit 1
                ;;
        esac
    done

    echo "========================================"
    echo "  GKE Authorized Networks 업데이트"
    echo "========================================"
    echo ""

    check_prerequisites
    get_current_ip
    get_existing_networks

    if check_ip_exists; then
        verify_access
        exit 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] 업데이트할 CIDR: ${EXISTING_CIDRS},${CURRENT_CIDR}"
        exit 0
    fi

    update_networks
    verify_access

    echo ""
    log_info "완료"
}

main "$@"
