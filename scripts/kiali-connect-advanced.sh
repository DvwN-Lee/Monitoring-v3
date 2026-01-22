#!/bin/bash

set -e

# 설정 (환경 변수로 오버라이드 가능)
PROJECT_ID="${GCP_PROJECT_ID:-titanium-k3s-1765951764}"
FIREWALL_RULE="${KIALI_FIREWALL_RULE:-titanium-k3s-allow-dashboards}"
MASTER_IP="${KIALI_MASTER_IP:-34.50.8.19}"
KIALI_PORT="${KIALI_PORT:-31200}"
BASE_ALLOWED_IP="${KIALI_BASE_IP:-}"  # 항상 유지할 IP (환경 변수로 설정)
MAX_ALLOWED_IPS="${KIALI_MAX_IPS:-10}"  # 최대 허용 IP 개수

# IP 기록 파일 경로
IP_HISTORY_FILE="${HOME}/.kiali-ip-history"

# IP 확인 함수 (fallback 지원)
get_current_ip() {
    local ip=""
    local services=("ifconfig.me" "icanhazip.com" "ipinfo.io/ip" "api.ipify.org")

    for service in "${services[@]}"; do
        ip=$(curl -s --connect-timeout 5 "$service" 2>/dev/null)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# IP 형식 검증 함수
validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    return 1
}

echo "=== Kiali 자동 접속 스크립트 (고급) ==="

# 1. 현재 IP 확인
echo "현재 IP 확인 중..."
CURRENT_IP=$(get_current_ip)
if [ -z "$CURRENT_IP" ]; then
    echo "ERROR: 현재 IP를 확인할 수 없습니다."
    echo "네트워크 연결을 확인하세요."
    exit 1
fi

if ! validate_ip "$CURRENT_IP"; then
    echo "ERROR: 유효하지 않은 IP 형식: $CURRENT_IP"
    exit 1
fi
echo "현재 IP: $CURRENT_IP"

# 2. IP 기록 파일에 현재 IP와 타임스탬프 저장
CURRENT_TIMESTAMP=$(date +%s)
if [ ! -f "$IP_HISTORY_FILE" ]; then
    touch "$IP_HISTORY_FILE"
fi

# 임시 파일 생성 (mktemp 사용)
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# 기존 기록에서 현재 IP 제거 (중복 방지)
grep -v "^${CURRENT_IP}," "$IP_HISTORY_FILE" > "$TEMP_FILE" 2>/dev/null || true
mv "$TEMP_FILE" "$IP_HISTORY_FILE"

# 현재 IP 추가
echo "${CURRENT_IP},${CURRENT_TIMESTAMP}" >> "$IP_HISTORY_FILE"

# 3. 현재 방화벽 규칙 확인
echo "방화벽 규칙 확인 중..."
CURRENT_RANGES=$(gcloud compute firewall-rules describe "$FIREWALL_RULE" \
    --project="$PROJECT_ID" \
    --format="value(sourceRanges)")

# 4. 허용할 IP 목록 생성
# - BASE_ALLOWED_IP는 항상 포함 (설정된 경우)
# - 최근 사용한 IP들을 최대 MAX_ALLOWED_IPS개까지 포함
echo "허용할 IP 목록 생성 중..."

# 최근 IP들 추출 (최신순 정렬)
# 임시 파일 생성 (mktemp 사용)
SORTED_FILE=$(mktemp)
trap "rm -f $TEMP_FILE $SORTED_FILE" EXIT

sort -t',' -k2 -rn "$IP_HISTORY_FILE" | head -n "$MAX_ALLOWED_IPS" | cut -d',' -f1 > "$SORTED_FILE"
RECENT_IPS=$(cat "$SORTED_FILE")

# 새로운 IP 범위 생성
if [ -n "$BASE_ALLOWED_IP" ]; then
    NEW_RANGES="$BASE_ALLOWED_IP"
else
    NEW_RANGES=""
fi

for ip in $RECENT_IPS; do
    if [ -n "$NEW_RANGES" ]; then
        NEW_RANGES="${NEW_RANGES},${ip}/32"
    else
        NEW_RANGES="${ip}/32"
    fi
done

# 중복 제거
NEW_RANGES=$(echo "$NEW_RANGES" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')

# 5. 방화벽 규칙 업데이트 (변경이 있는 경우만)
if [ "$CURRENT_RANGES" != "$NEW_RANGES" ]; then
    echo "방화벽 규칙 업데이트 중..."
    echo "이전: $CURRENT_RANGES"
    echo "이후: $NEW_RANGES"

    gcloud compute firewall-rules update "$FIREWALL_RULE" \
        --project="$PROJECT_ID" \
        --source-ranges="$NEW_RANGES" \
        --quiet

    echo "[OK] 방화벽 규칙 업데이트 완료"
else
    echo "[OK] 방화벽 규칙 변경 불필요"
fi

# 6. IP 기록 정리 (오래된 기록 삭제)
# 30일 이상 된 기록 삭제
CUTOFF_TIME=$((CURRENT_TIMESTAMP - 30*24*60*60))
CLEANUP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE $SORTED_FILE $CLEANUP_FILE" EXIT

awk -F',' -v cutoff=$CUTOFF_TIME '$2 >= cutoff' "$IP_HISTORY_FILE" > "$CLEANUP_FILE"
mv "$CLEANUP_FILE" "$IP_HISTORY_FILE"

# 7. Kiali URL 출력 및 브라우저 열기
KIALI_URL="http://${MASTER_IP}:${KIALI_PORT}/kiali"
echo ""
echo "=== Kiali 접속 정보 ==="
echo "URL: $KIALI_URL"
echo "현재 허용된 IP 개수: $(echo "$NEW_RANGES" | tr ',' '\n' | wc -l | xargs)"
echo ""
echo "브라우저를 여는 중..."

# OS에 따라 브라우저 열기
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    open "$KIALI_URL"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    xdg-open "$KIALI_URL" 2>/dev/null || echo "브라우저를 수동으로 열어주세요: $KIALI_URL"
else
    echo "브라우저를 수동으로 열어주세요: $KIALI_URL"
fi

echo ""
echo "=== 접속 완료 ==="
echo ""
echo "팁: IP 기록은 ~/.kiali-ip-history에 저장됩니다."
echo "팁: 최대 ${MAX_ALLOWED_IPS}개의 최근 IP가 유지됩니다."
