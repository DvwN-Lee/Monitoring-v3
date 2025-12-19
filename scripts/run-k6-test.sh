#!/bin/bash

# k6 부하 테스트 실행 스크립트
# 사용법:
#   ./scripts/run-k6-test.sh [quick|load]
#   기본값: quick

set -e

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 테스트 타입 (기본값: quick)
TEST_TYPE=${1:-quick}

# Cluster 정보 확인
echo -e "${BLUE}[INFO]${NC} Cluster 정보 확인 중..."

# Node IP 가져오기
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
if [ -z "$NODE_IP" ]; then
    echo -e "${RED}[ERROR]${NC} Node IP를 가져올 수 없습니다."
    exit 1
fi

# Istio Ingress Gateway NodePort 가져오기
NODEPORT=$(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
if [ -z "$NODEPORT" ]; then
    echo -e "${RED}[ERROR]${NC} Istio Ingress Gateway NodePort를 가져올 수 없습니다."
    exit 1
fi

BASE_URL="http://${NODE_IP}:${NODEPORT}"

echo -e "${GREEN}[✓]${NC} Cluster 접속 정보:"
echo -e "  - Node IP: ${NODE_IP}"
echo -e "  - NodePort: ${NODEPORT}"
echo -e "  - BASE_URL: ${BASE_URL}"
echo ""

# k6 설치 확인
if ! command -v k6 &> /dev/null; then
    echo -e "${YELLOW}[WARNING]${NC} k6가 설치되어 있지 않습니다."
    echo ""
    echo "k6 설치 방법:"
    echo ""
    echo "macOS (Homebrew):"
    echo "  brew install k6"
    echo ""
    echo "Ubuntu/Debian:"
    echo "  sudo gpg -k"
    echo "  sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69"
    echo "  echo \"deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main\" | sudo tee /etc/apt/sources.list.d/k6.list"
    echo "  sudo apt-get update"
    echo "  sudo apt-get install k6"
    echo ""
    echo "Docker:"
    echo "  docker run --rm -i grafana/k6 run - <tests/performance/${TEST_TYPE}-test.js"
    echo ""
    exit 1
fi

# 테스트 타입에 따라 스크립트 선택
case "$TEST_TYPE" in
    quick)
        TEST_SCRIPT="tests/performance/quick-test.js"
        echo -e "${BLUE}[INFO]${NC} Quick 테스트 실행 (약 2분 소요)"
        ;;
    load)
        TEST_SCRIPT="tests/performance/load-test.js"
        echo -e "${BLUE}[INFO]${NC} Load 테스트 실행 (약 10분 소요)"
        ;;
    *)
        echo -e "${RED}[ERROR]${NC} 잘못된 테스트 타입: $TEST_TYPE"
        echo "사용 가능한 타입: quick, load"
        exit 1
        ;;
esac

# 테스트 스크립트 존재 확인
if [ ! -f "$TEST_SCRIPT" ]; then
    echo -e "${RED}[ERROR]${NC} 테스트 스크립트를 찾을 수 없습니다: $TEST_SCRIPT"
    exit 1
fi

# k6 테스트 실행
echo -e "${BLUE}[INFO]${NC} k6 테스트 시작..."
echo ""

BASE_URL=$BASE_URL k6 run "$TEST_SCRIPT"

# 결과 확인
echo ""
echo -e "${GREEN}[✓]${NC} k6 테스트 완료!"
echo ""

# 결과 파일 확인
if [ "$TEST_TYPE" = "quick" ]; then
    RESULT_FILE="tests/performance/quick-results.json"
else
    RESULT_FILE="tests/performance/results.json"
fi

if [ -f "$RESULT_FILE" ]; then
    echo -e "${BLUE}[INFO]${NC} 결과 파일: $RESULT_FILE"
fi
