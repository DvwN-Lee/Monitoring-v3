# Project Plan

## 프로젝트 개요

| 항목 | 내용 |
|------|------|
| 프로젝트명 | Monitoring-v3 |
| 목표 | GCP 기반 End-to-End Infrastructure 자동화 및 Observability 구현 |
| 기간 | 2025-12-18 ~ 2026-02-10 (약 8주) |
| 커밋 수 | 676 |

## Phase별 구현 내역

### Phase 1: Infrastructure 기반 구축 (2025-12-18 ~ 12-25)

| Milestone | 상태 | 주요 산출물 |
|-----------|------|------------|
| GCP Terraform 코드 작성 | 완료 | VPC, Subnet, Firewall, Compute Instance |
| K3s Bootstrap 자동화 | 완료 | `k3s-server.sh`, `k3s-agent.sh` |
| ArgoCD App of Apps 구조 | 완료 | `apps/root-app.yaml`, infrastructure/ |
| Monitoring-v2 서비스 코드 이관 | 완료 | api-gateway, auth/user/blog-service |
| Terratest 설계 및 Layer 0-2 구현 | 완료 | Static Validation, Plan Unit, Plan Deep Analysis, Network Layer |

### Phase 2: Security 강화 (2025-12-28 ~ 2026-01-05)

| Milestone | 상태 | 주요 산출물 |
|-----------|------|------------|
| GCP Firewall CIDR Validation | 완료 | `0.0.0.0/0` 차단, 특정 IP 제한 |
| CORS wildcard 제거 | 완료 | Domain 기반 제한 |
| API Gateway Security Headers | 완료 | HSTS, CSP, X-Frame-Options |
| HTTPS/TLS 자동 생성 | 완료 | Bootstrap Script 내 cert 생성 |
| JWT RS256 인증 | 완료 | RSA Key Pair 기반 |

### Phase 3: Testing 자동화 (2026-01-06 ~ 01-16)

| Milestone | 상태 | 주요 산출물 |
|-----------|------|------------|
| Terratest Layer 3-5 구현 | 완료 | Compute & K3s, Full Integration, Monitoring Stack |
| 코드 레벨 단위 테스트 | 완료 | pytest (Python), go test (Go) |
| ArgoCD Degraded 대응 로직 | 완료 | `Functionally Ready` 패턴 |
| Monitoring Stack 자동화 배포 | 완료 | kube-prometheus-stack, loki-stack |

### Phase 4: Service Mesh + Secret Management (2026-01-17 ~ 01-31)

| Milestone | 상태 | 주요 산출물 |
|-----------|------|------------|
| Istio mTLS 정책 공식화 및 전체 검증 | 완료 | PeerAuthentication, DestinationRule (초기 적용: Phase 1) |
| Zero Trust NetworkPolicy | 완료 | Default Deny + Explicit Allow |
| External Secrets + GCP Secret Manager | 완료 | ClusterSecretStore, ExternalSecret |
| ESO ADC 인증 전환 | 완료 | SA Key JSON 제거, GCE Metadata 활용 |
| Kiali Dashboard 연동 | 완료 | Traffic Graph, Workload Health |

### Phase 5: Production 안정화 (2026-02-01 ~ 02-10)

| Milestone | 상태 | 주요 산출물 |
|-----------|------|------------|
| IaC 배포 문제 해결 (10건) | 완료 | `docs/TROUBLESHOOTING.md` Part 1 |
| Kiali multi-cluster 이슈 해결 | 완료 | Single-cluster 설정 최적화 |
| 문서-코드 정합성 검증 | 완료 | Architecture, Demo, ADR |
| Demo 검증 및 스크린샷 | 완료 | `docs/demo/` (23종) |

## Risk Matrix

발생 확률(1-5)과 영향도(1-5)를 곱한 Risk Score 기준으로 관리한다.

| Risk | 확률 | 영향 | Score | 대응 | 결과 |
|------|------|------|-------|------|------|
| K3s Single Master 장애 | 2 | 5 | 10 | etcd snapshot 자동 백업 | 수용 (비용 대비 HA 불필요) |
| GCP Free Tier 초과 비용 | 3 | 3 | 9 | Spot VM 활용, 리소스 최소 사양 | e2-medium/e2-standard-2 |
| Secret 유출 | 1 | 5 | 5 | External Secrets + GCP Secret Manager | ADR-005 |
| Bootstrap 타이밍 이슈 | 4 | 3 | 12 | Sync Wave, retry 로직 | Troubleshooting 10건 문서화 |
| Istio 학습 곡선 | 3 | 3 | 9 | 단계적 도입 (Gateway → mTLS → NetworkPolicy) | ADR-004, ADR-006 |
| Terratest 비용 | 3 | 2 | 6 | Layer 0-1.5 무비용, Layer 2+ 선택적 실행 | Bottom-Up 전략 채택 |

## 기술 의사결정 Timeline

```
2025-12-18  프로젝트 시작
2025-12-31  ADR-001 (GCP + K3s), ADR-002 (ArgoCD), ADR-003 (Terraform)
2026-01-10  ADR-007 (Monitoring Stack)
2026-01-15  ADR-004 (Istio Service Mesh)
2026-01-20  ADR-005 (External Secrets)
2026-01-25  ADR-006 (Zero Trust NetworkPolicy)
2026-02-10  Production 문서 정비 완료
```

## 관련 문서

- [Requirements](requirements.md)
- [Architecture](../architecture/README.md)
- [ADR Index](../architecture/adr/README.md)
- [Implementation Summary](../03-implementation/implementation-summary.md)
