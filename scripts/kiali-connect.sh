#!/bin/bash

set -e

PROJECT_ID="titanium-k3s-1765951764"
FIREWALL_RULE="titanium-k3s-allow-dashboards"
MASTER_IP="34.50.8.19"
KIALI_PORT="31200"
BASE_ALLOWED_IP="112.218.39.251/32"

echo "=== Kiali 자동 접속 스크립트 ==="

# 1. 현재 IP 확인
echo "현재 IP 확인 중..."
CURRENT_IP=$(curl -s ifconfig.me)
if [ -z "$CURRENT_IP" ]; then
    echo "ERROR: 현재 IP를 확인할 수 없습니다."
    exit 1
fi
echo "현재 IP: $CURRENT_IP"

# 2. 현재 방화벽 규칙 확인
echo "방화벽 규칙 확인 중..."
CURRENT_RANGES=$(gcloud compute firewall-rules describe $FIREWALL_RULE \
    --project=$PROJECT_ID \
    --format="value(sourceRanges)")

# 3. 현재 IP가 이미 허용되어 있는지 확인
if echo "$CURRENT_RANGES" | grep -q "$CURRENT_IP"; then
    echo "✓ 현재 IP($CURRENT_IP)가 이미 허용되어 있습니다."
else
    echo "현재 IP를 방화벽 규칙에 추가 중..."

    # 기존 IP 목록에 현재 IP 추가
    NEW_RANGES="${CURRENT_RANGES},${CURRENT_IP}/32"

    gcloud compute firewall-rules update $FIREWALL_RULE \
        --project=$PROJECT_ID \
        --source-ranges="$NEW_RANGES" \
        --quiet

    echo "✓ 방화벽 규칙 업데이트 완료"
fi

# 4. Kiali URL 출력 및 브라우저 열기
KIALI_URL="http://${MASTER_IP}:${KIALI_PORT}/kiali"
echo ""
echo "=== Kiali 접속 정보 ==="
echo "URL: $KIALI_URL"
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
