#!/bin/bash
# GCP k3s Cluster 전체 백업 스크립트
# 실행: ./scripts/backup-gcp.sh

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== GCP k3s Cluster 백업 시작 ===${NC}"
echo ""

# 환경 변수 설정
export BACKUP_DATE=$(date +%Y%m%d-%H%M%S)
export BACKUP_BASE_DIR=~/gcp-k3s-backup
export BACKUP_DIR=$BACKUP_BASE_DIR/$(date +%Y%m%d)
export NAMESPACE=titanium-prod
export PG_POD=postgresql-0

# 백업 디렉토리 생성
mkdir -p $BACKUP_DIR
cd $BACKUP_DIR

echo -e "${YELLOW}백업 디렉토리: $BACKUP_DIR${NC}"
echo ""

# Cluster 연결 확인
echo -e "${GREEN}[1/8] Cluster 연결 확인${NC}"
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}ERROR: Kubernetes Cluster에 연결할 수 없습니다${NC}"
    echo "먼저 ./scripts/switch-to-cloud.sh를 실행하세요"
    exit 1
fi

CURRENT_CONTEXT=$(kubectl config current-context)
echo "현재 컨텍스트: $CURRENT_CONTEXT"
echo ""

# PostgreSQL Pod 상태 확인
echo -e "${GREEN}[2/8] PostgreSQL Pod 상태 확인${NC}"
if ! kubectl get pod $PG_POD -n $NAMESPACE &> /dev/null; then
    echo -e "${RED}ERROR: PostgreSQL Pod를 찾을 수 없습니다${NC}"
    exit 1
fi

PG_STATUS=$(kubectl get pod $PG_POD -n $NAMESPACE -o jsonpath='{.status.phase}')
echo "PostgreSQL Pod 상태: $PG_STATUS"

if [ "$PG_STATUS" != "Running" ]; then
    echo -e "${RED}ERROR: PostgreSQL Pod가 Running 상태가 아닙니다${NC}"
    exit 1
fi
echo ""

# 현재 데이터 카운트 확인
echo -e "${GREEN}[3/8] 현재 데이터 카운트 확인${NC}"
kubectl exec -n $NAMESPACE $PG_POD -- psql -U postgres -d titanium -c "
SELECT
  'users' as table_name, COUNT(*) as count FROM users
UNION ALL
SELECT
  'posts' as table_name, COUNT(*) as count FROM posts;
" | tee $BACKUP_DIR/data-count-before-$BACKUP_DATE.txt
echo ""

# PostgreSQL 전체 백업
echo -e "${GREEN}[4/8] PostgreSQL 데이터베이스 백업${NC}"
echo "SQL 형식 백업 중..."
kubectl exec -n $NAMESPACE $PG_POD -- pg_dump -U postgres -d titanium > \
  $BACKUP_DIR/postgresql-titanium-$BACKUP_DATE.sql

echo "압축 형식 백업 중..."
kubectl exec -n $NAMESPACE $PG_POD -- pg_dump -U postgres -d titanium -Fc > \
  $BACKUP_DIR/postgresql-titanium-$BACKUP_DATE.dump

echo "전체 데이터베이스 백업 (pg_dumpall)..."
kubectl exec -n $NAMESPACE $PG_POD -- pg_dumpall -U postgres > \
  $BACKUP_DIR/postgresql-all-$BACKUP_DATE.sql

echo "백업 파일:"
ls -lh $BACKUP_DIR/postgresql-*
echo ""

# Redis 백업
echo -e "${GREEN}[5/8] Redis 데이터 백업${NC}"
REDIS_POD=$(kubectl get pods -n $NAMESPACE -l app=prod-redis -o jsonpath='{.items[0].metadata.name}')
echo "Redis Pod: $REDIS_POD"

# Redis SAVE 명령으로 스냅샷 생성
kubectl exec -n $NAMESPACE $REDIS_POD -- redis-cli SAVE

# RDB 파일 복사
kubectl cp $NAMESPACE/$REDIS_POD:/data/dump.rdb $BACKUP_DIR/redis-dump-$BACKUP_DATE.rdb

echo "Redis 백업 완료: redis-dump-$BACKUP_DATE.rdb"
echo ""

# Kubernetes 리소스 백업
echo -e "${GREEN}[6/8] Kubernetes 리소스 백업${NC}"

# 전체 Namespace 리소스
kubectl get all -n $NAMESPACE -o yaml > $BACKUP_DIR/k8s-all-resources-$BACKUP_DATE.yaml

# 개별 리소스 타입
kubectl get deployments -n $NAMESPACE -o yaml > $BACKUP_DIR/k8s-deployments-$BACKUP_DATE.yaml
kubectl get statefulsets -n $NAMESPACE -o yaml > $BACKUP_DIR/k8s-statefulsets-$BACKUP_DATE.yaml
kubectl get services -n $NAMESPACE -o yaml > $BACKUP_DIR/k8s-services-$BACKUP_DATE.yaml
kubectl get configmaps -n $NAMESPACE -o yaml > $BACKUP_DIR/k8s-configmaps-$BACKUP_DATE.yaml
kubectl get secrets -n $NAMESPACE -o yaml > $BACKUP_DIR/k8s-secrets-$BACKUP_DATE.yaml
kubectl get pvc -n $NAMESPACE -o yaml > $BACKUP_DIR/k8s-pvc-$BACKUP_DATE.yaml

# Istio 리소스 (있는 경우)
kubectl get virtualservices -n $NAMESPACE -o yaml > $BACKUP_DIR/k8s-virtualservices-$BACKUP_DATE.yaml 2>/dev/null || true
kubectl get destinationrules -n $NAMESPACE -o yaml > $BACKUP_DIR/k8s-destinationrules-$BACKUP_DATE.yaml 2>/dev/null || true
kubectl get gateways -n $NAMESPACE -o yaml > $BACKUP_DIR/k8s-gateways-$BACKUP_DATE.yaml 2>/dev/null || true

echo "Kubernetes 리소스 백업 완료"
echo ""

# Terraform 상태 백업
echo -e "${GREEN}[7/8] Terraform 상태 백업${NC}"
TERRAFORM_DIR=~/Desktop/Git/Monitoring-v3/terraform/environments/gcp

if [ -d "$TERRAFORM_DIR" ]; then
    cd $TERRAFORM_DIR

    # State pull
    if terraform state pull > $BACKUP_DIR/terraform-state-$BACKUP_DATE.json 2>/dev/null; then
        echo "Terraform state 백업 완료"
    else
        echo -e "${YELLOW}WARNING: Terraform state 백업 실패 (무시하고 진행)${NC}"
    fi

    # 리소스 목록
    terraform state list > $BACKUP_DIR/terraform-resources-$BACKUP_DATE.txt 2>/dev/null || true

    # Outputs
    terraform output -json > $BACKUP_DIR/terraform-outputs-$BACKUP_DATE.json 2>/dev/null || true

    cd $BACKUP_DIR
else
    echo -e "${YELLOW}WARNING: Terraform 디렉토리를 찾을 수 없습니다${NC}"
fi
echo ""

# 백업 매니페스트 생성
echo -e "${GREEN}[8/8] 백업 매니페스트 생성${NC}"
cat > $BACKUP_DIR/BACKUP_MANIFEST.txt <<EOF
=== GCP k3s Backup Manifest ===
Backup Date: $BACKUP_DATE
Backup Directory: $BACKUP_DIR
Cluster Context: $CURRENT_CONTEXT
Namespace: $NAMESPACE

=== PostgreSQL Info ===
Pod: $PG_POD
Database: titanium
Version: $(kubectl exec -n $NAMESPACE $PG_POD -- psql -U postgres -t -c "SELECT version();" | head -1)

=== Data Count ===
$(cat $BACKUP_DIR/data-count-before-$BACKUP_DATE.txt)

=== Redis Info ===
Pod: $REDIS_POD

=== Backup Files ===
$(ls -lh $BACKUP_DIR | grep -v total)

=== Verification ===
Date: $(date)
Verified by: $(whoami)
Hostname: $(hostname)
Status: OK
EOF

echo "백업 매니페스트 생성 완료"
cat $BACKUP_DIR/BACKUP_MANIFEST.txt
echo ""

# 백업 압축
echo -e "${GREEN}백업 압축 중...${NC}"
cd $BACKUP_BASE_DIR
ARCHIVE_NAME="gcp-k3s-backup-$BACKUP_DATE.tar.gz"
tar czf $ARCHIVE_NAME $(basename $BACKUP_DIR)

# 체크섬 생성
shasum -a 256 $ARCHIVE_NAME > $ARCHIVE_NAME.sha256

echo -e "${GREEN}백업 아카이브 생성 완료${NC}"
echo "파일: $BACKUP_BASE_DIR/$ARCHIVE_NAME"
echo "크기: $(du -sh $BACKUP_BASE_DIR/$ARCHIVE_NAME | cut -f1)"
echo "체크섬: $(cat $ARCHIVE_NAME.sha256)"
echo ""

# 최종 요약
echo -e "${GREEN}=== 백업 완료 ===${NC}"
echo ""
echo "백업 위치:"
echo "  - 디렉토리: $BACKUP_DIR"
echo "  - 아카이브: $BACKUP_BASE_DIR/$ARCHIVE_NAME"
echo ""
echo "다음 단계:"
echo "  1. 백업 검증: cat $BACKUP_DIR/BACKUP_MANIFEST.txt"
echo "  2. 오프사이트 백업: 외부 저장소로 아카이브 복사"
echo "  3. Cluster 삭제: terraform destroy (백업 검증 후)"
echo "  4. 복구: ./scripts/restore-gcp.sh"
echo ""
