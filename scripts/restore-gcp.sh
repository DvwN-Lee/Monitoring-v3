#!/bin/bash
# GCP k3s Cluster 데이터 복구 스크립트
# 실행: ./scripts/restore-gcp.sh <backup-directory>

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== GCP k3s Cluster 복구 시작 ===${NC}"
echo ""

# 인자 확인
if [ -z "$1" ]; then
    echo -e "${RED}ERROR: 백업 디렉토리를 지정하세요${NC}"
    echo "사용법: $0 <backup-directory>"
    echo ""
    echo "예시:"
    echo "  $0 ~/gcp-k3s-backup/20250124"
    echo ""
    echo "가능한 백업 디렉토리:"
    ls -d ~/gcp-k3s-backup/*/ 2>/dev/null | head -5 || echo "  (백업 없음)"
    exit 1
fi

BACKUP_DIR=$1

if [ ! -d "$BACKUP_DIR" ]; then
    echo -e "${RED}ERROR: 백업 디렉토리를 찾을 수 없습니다: $BACKUP_DIR${NC}"
    exit 1
fi

echo -e "${YELLOW}백업 디렉토리: $BACKUP_DIR${NC}"
echo ""

# 백업 매니페스트 확인
if [ -f "$BACKUP_DIR/BACKUP_MANIFEST.txt" ]; then
    echo -e "${GREEN}백업 매니페스트:${NC}"
    cat $BACKUP_DIR/BACKUP_MANIFEST.txt
    echo ""
else
    echo -e "${YELLOW}WARNING: 백업 매니페스트를 찾을 수 없습니다${NC}"
fi

# 사용자 확인
echo -e "${YELLOW}이 백업으로 복구하시겠습니까? (yes/no)${NC}"
read CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "복구 취소됨"
    exit 0
fi

# 환경 변수 설정
export NAMESPACE=titanium-prod
export PG_POD=postgresql-0

# Cluster 연결 확인
echo -e "${GREEN}[1/7] Cluster 연결 확인${NC}"
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}ERROR: Kubernetes Cluster에 연결할 수 없습니다${NC}"
    echo "먼저 GCP Cluster kubeconfig를 설정하세요:"
    echo "  export KUBECONFIG=~/.kube/config-gcp"
    exit 1
fi

CURRENT_CONTEXT=$(kubectl config current-context)
echo "현재 컨텍스트: $CURRENT_CONTEXT"
echo ""

# Namespace 확인 및 생성
echo -e "${GREEN}[2/7] Namespace 확인${NC}"
if ! kubectl get namespace $NAMESPACE &> /dev/null; then
    echo "Namespace 생성 중: $NAMESPACE"
    kubectl create namespace $NAMESPACE
    kubectl label namespace $NAMESPACE istio-injection=enabled
else
    echo "Namespace 존재: $NAMESPACE"
fi
echo ""

# Secret 및 ConfigMap 복구
echo -e "${GREEN}[3/7] Secret 및 ConfigMap 복구${NC}"

# 최신 백업 파일 찾기
SECRET_FILE=$(ls -t $BACKUP_DIR/k8s-secrets-*.yaml 2>/dev/null | head -1)
CONFIGMAP_FILE=$(ls -t $BACKUP_DIR/k8s-configmaps-*.yaml 2>/dev/null | head -1)

if [ -f "$SECRET_FILE" ]; then
    echo "Secret 복구 중..."
    kubectl apply -f $SECRET_FILE || echo -e "${YELLOW}WARNING: Secret 복구 중 일부 오류 발생${NC}"
else
    echo -e "${YELLOW}WARNING: Secret 백업 파일을 찾을 수 없습니다${NC}"
fi

if [ -f "$CONFIGMAP_FILE" ]; then
    echo "ConfigMap 복구 중..."
    kubectl apply -f $CONFIGMAP_FILE || echo -e "${YELLOW}WARNING: ConfigMap 복구 중 일부 오류 발생${NC}"
else
    echo -e "${YELLOW}WARNING: ConfigMap 백업 파일을 찾을 수 없습니다${NC}"
fi
echo ""

# PVC 복구
echo -e "${GREEN}[4/7] PVC 복구${NC}"
PVC_FILE=$(ls -t $BACKUP_DIR/k8s-pvc-*.yaml 2>/dev/null | head -1)

if [ -f "$PVC_FILE" ]; then
    echo "PVC 생성 중..."
    kubectl apply -f $PVC_FILE || echo -e "${YELLOW}WARNING: PVC 복구 중 일부 오류 발생${NC}"

    echo "PVC Bound 대기 중..."
    kubectl wait --for=condition=Bound pvc --all -n $NAMESPACE --timeout=120s || \
        echo -e "${YELLOW}WARNING: 일부 PVC가 Bound 상태가 되지 않았습니다${NC}"
else
    echo -e "${YELLOW}WARNING: PVC 백업 파일을 찾을 수 없습니다${NC}"
fi
echo ""

# StatefulSet 복구 (PostgreSQL)
echo -e "${GREEN}[5/7] PostgreSQL StatefulSet 복구${NC}"
STATEFULSET_FILE=$(ls -t $BACKUP_DIR/k8s-statefulsets-*.yaml 2>/dev/null | head -1)

if [ -f "$STATEFULSET_FILE" ]; then
    echo "StatefulSet 생성 중..."
    kubectl apply -f $STATEFULSET_FILE || echo -e "${YELLOW}WARNING: StatefulSet 복구 중 일부 오류 발생${NC}"

    echo "PostgreSQL Pod 준비 대기 중 (최대 5분)..."
    kubectl wait --for=condition=Ready pod/$PG_POD -n $NAMESPACE --timeout=300s || \
        echo -e "${YELLOW}WARNING: PostgreSQL Pod가 준비되지 않았습니다${NC}"

    # Pod 상태 확인
    kubectl get pod $PG_POD -n $NAMESPACE
else
    echo -e "${RED}ERROR: StatefulSet 백업 파일을 찾을 수 없습니다${NC}"
    exit 1
fi
echo ""

# PostgreSQL 데이터 복구
echo -e "${GREEN}[6/7] PostgreSQL 데이터 복구${NC}"

# PostgreSQL 연결 확인
echo "PostgreSQL 연결 테스트..."
if ! kubectl exec -n $NAMESPACE $PG_POD -- psql -U postgres -d titanium -c "SELECT 1;" &> /dev/null; then
    echo -e "${RED}ERROR: PostgreSQL에 연결할 수 없습니다${NC}"
    exit 1
fi

# 백업 파일 찾기
SQL_BACKUP=$(ls -t $BACKUP_DIR/postgresql-titanium-*.sql 2>/dev/null | grep -v "all" | head -1)
DUMP_BACKUP=$(ls -t $BACKUP_DIR/postgresql-titanium-*.dump 2>/dev/null | head -1)

if [ -f "$SQL_BACKUP" ]; then
    echo "SQL 백업 파일로 복구 중: $(basename $SQL_BACKUP)"

    # 기존 데이터 삭제
    echo "기존 테이블 삭제 중..."
    kubectl exec -n $NAMESPACE $PG_POD -- psql -U postgres -d titanium -c "
    DROP TABLE IF EXISTS users CASCADE;
    DROP TABLE IF EXISTS posts CASCADE;
    " || echo -e "${YELLOW}WARNING: 기존 테이블 삭제 실패 (무시하고 진행)${NC}"

    # 데이터 복구
    echo "데이터 복구 중 (몇 분 소요될 수 있습니다)..."
    cat $SQL_BACKUP | kubectl exec -i -n $NAMESPACE $PG_POD -- psql -U postgres -d titanium

    echo "데이터 복구 완료"

elif [ -f "$DUMP_BACKUP" ]; then
    echo "DUMP 백업 파일로 복구 중: $(basename $DUMP_BACKUP)"

    # Pod로 파일 복사
    kubectl cp $DUMP_BACKUP $NAMESPACE/$PG_POD:/tmp/restore.dump

    # 복구
    kubectl exec -n $NAMESPACE $PG_POD -- pg_restore -U postgres -d titanium -c /tmp/restore.dump

    # 임시 파일 삭제
    kubectl exec -n $NAMESPACE $PG_POD -- rm /tmp/restore.dump

    echo "데이터 복구 완료"
else
    echo -e "${RED}ERROR: PostgreSQL 백업 파일을 찾을 수 없습니다${NC}"
    exit 1
fi

# 데이터 검증
echo ""
echo "복구된 데이터 확인:"
kubectl exec -n $NAMESPACE $PG_POD -- psql -U postgres -d titanium -c "
SELECT
  'users' as table_name, COUNT(*) as count FROM users
UNION ALL
SELECT
  'posts' as table_name, COUNT(*) as count FROM posts;
"
echo ""

# 나머지 리소스 복구
echo -e "${GREEN}[7/7] 나머지 리소스 복구${NC}"

# Deployment 복구
DEPLOYMENT_FILE=$(ls -t $BACKUP_DIR/k8s-deployments-*.yaml 2>/dev/null | head -1)
if [ -f "$DEPLOYMENT_FILE" ]; then
    echo "Deployment 복구 중..."
    kubectl apply -f $DEPLOYMENT_FILE || echo -e "${YELLOW}WARNING: Deployment 복구 중 일부 오류 발생${NC}"
fi

# Service 복구
SERVICE_FILE=$(ls -t $BACKUP_DIR/k8s-services-*.yaml 2>/dev/null | head -1)
if [ -f "$SERVICE_FILE" ]; then
    echo "Service 복구 중..."
    kubectl apply -f $SERVICE_FILE || echo -e "${YELLOW}WARNING: Service 복구 중 일부 오류 발생${NC}"
fi

# Istio 리소스 복구
VS_FILE=$(ls -t $BACKUP_DIR/k8s-virtualservices-*.yaml 2>/dev/null | head -1)
if [ -f "$VS_FILE" ] && [ -s "$VS_FILE" ]; then
    echo "VirtualService 복구 중..."
    kubectl apply -f $VS_FILE 2>/dev/null || true
fi

DR_FILE=$(ls -t $BACKUP_DIR/k8s-destinationrules-*.yaml 2>/dev/null | head -1)
if [ -f "$DR_FILE" ] && [ -s "$DR_FILE" ]; then
    echo "DestinationRule 복구 중..."
    kubectl apply -f $DR_FILE 2>/dev/null || true
fi

GW_FILE=$(ls -t $BACKUP_DIR/k8s-gateways-*.yaml 2>/dev/null | head -1)
if [ -f "$GW_FILE" ] && [ -s "$GW_FILE" ]; then
    echo "Gateway 복구 중..."
    kubectl apply -f $GW_FILE 2>/dev/null || true
fi

echo ""
echo "모든 Pod가 Ready 상태가 될 때까지 대기 중 (최대 10분)..."
kubectl wait --for=condition=Ready pod --all -n $NAMESPACE --timeout=600s || \
    echo -e "${YELLOW}WARNING: 일부 Pod가 준비되지 않았습니다${NC}"

echo ""
echo -e "${GREEN}=== 복구 완료 ===${NC}"
echo ""

# 최종 상태 확인
echo "현재 리소스 상태:"
kubectl get all -n $NAMESPACE
echo ""

echo "다음 단계:"
echo "  1. 데이터 검증: kubectl exec -n $NAMESPACE $PG_POD -- psql -U postgres -d titanium -c 'SELECT COUNT(*) FROM users;'"
echo "  2. API 테스트: curl http://\$INGRESS_IP/api/users/"
echo "  3. 모니터링: kubectl get pods -n $NAMESPACE -w"
echo ""
