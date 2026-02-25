# ADR-008: PostgreSQL Database 선택

**날짜**: 2025-12-28

---

## 상황 (Context)

Monitoring-v2에서는 SQLite를 사용했다. v3에서는 Kubernetes 환경에서 다중 Pod가 동시에 접근하는 구조로 변경되면서, 동시성 지원과 데이터 영속성을 보장하는 Database가 필요하다.

## 결정 (Decision)

PostgreSQL 15를 Kubernetes StatefulSet으로 배포하고, PersistentVolumeClaim을 통해 데이터를 영속화한다. 관리형 Database(Cloud SQL)가 아닌 Self-managed 방식을 선택한다.

## 이유 (Rationale)

| 항목 | SQLite | PostgreSQL (Self-managed) | Cloud SQL |
|------|--------|--------------------------|-----------|
| 동시 접근 | 파일 기반 Lock, 다중 Writer 불가 | MVCC 기반, 다중 동시 접근 지원 | 동일 |
| Kubernetes 호환성 | 단일 Pod 전용 | StatefulSet + PVC | 외부 연결 |
| 비용 | $0 | $0 (Cluster 내 배포) | 월 $10+ |
| 운영 부담 | 없음 | Backup/복구 직접 관리 | 자동 관리 |
| IaC 학습 범위 | 해당 없음 | StatefulSet, PVC, Secret 관리 | Cloud SQL Terraform |

v3의 목표가 Kubernetes 리소스 관리 학습을 포함하므로, Self-managed PostgreSQL이 적합하다. Cloud SQL은 비용 대비 학습 범위가 좁다.

FastAPI의 asyncpg 라이브러리와의 호환성이 검증되어 있으며, SQLAlchemy + Alembic을 통한 Schema Migration을 지원한다.

## 결과 (Consequences)

### 긍정적 측면
- 다중 Pod에서 동시 읽기/쓰기 가능
- StatefulSet + PVC를 통한 데이터 영속성 보장
- 추가 비용 없이 Cluster 내에서 운영
- asyncpg를 통한 비동기 I/O 성능 확보

### 부정적 측면 (Trade-offs)
- Backup/복구를 직접 관리해야 함 (pg_dump, etcd snapshot)
- PostgreSQL Pod 장애 시 수동 복구 필요 (Single Instance)
- Istio mTLS 환경에서 PostgreSQL 포트(5432) 제외 설정 필요
