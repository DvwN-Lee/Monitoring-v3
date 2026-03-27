# Requirements

MoSCoW 우선순위 분류 기반 프로젝트 요구사항 정의.

## 정량적 달성 요약

| 분류 | 항목 수 | 달성 | 달성률 |
|------|---------|------|--------|
| Must Have | 8 | 8 | 100% |
| Should Have | 6 | 6 | 100% |
| Could Have | 4 | 3 | 75% |
| Won't Have | 3 | - | - |
| **합계** | **18** | **17** | **94%** |

## Must Have (필수)

반드시 구현해야 하는 핵심 요구사항.

| ID | 요구사항 | 달성 | 관련 문서 |
|----|----------|------|-----------|
| M-1 | GCP IaaS 위에 K3s Cluster를 Terraform으로 자동 배포 | 완료 | [ADR-001](../architecture/adr/001-gcp-k3s-infrastructure.md) |
| M-2 | ArgoCD 기반 GitOps 배포 자동화 | 완료 | [ADR-002](../architecture/adr/002-gitops-argocd.md) |
| M-3 | Microservice 기반 Blog Application 운영 | 완료 | [Architecture](../architecture/README.md) |
| M-4 | Prometheus + Grafana 기반 Metrics 모니터링 | 완료 | [ADR-007](../architecture/adr/007-monitoring-stack.md) |
| M-5 | Loki 기반 로그 수집 및 조회 | 완료 | [ADR-007](../architecture/adr/007-monitoring-stack.md) |
| M-6 | GitHub Actions CI Pipeline | 완료 | `.github/workflows/ci.yml` |
| M-7 | Secret 외부 관리 (하드코딩 제거) | 완료 | [ADR-005](../architecture/adr/005-external-secrets-gcp.md) |
| M-8 | Infrastructure 테스트 자동화 (Terratest) | 완료 | `terraform/environments/gcp/test/` |

## Should Have (권장)

프로젝트 품질을 높이는 중요 요구사항.

| ID | 요구사항 | 달성 | 관련 문서 |
|----|----------|------|-----------|
| S-1 | Istio Service Mesh (mTLS) 적용 | 완료 | [ADR-004](../architecture/adr/004-istio-service-mesh.md) |
| S-2 | Zero Trust NetworkPolicy 모델 | 완료 | [ADR-006](../architecture/adr/006-zero-trust-networkpolicy.md) |
| S-3 | Kiali Service Mesh Dashboard | 완료 | [Demo](../demo/README.md) |
| S-4 | MIG Auto-healing (Worker Node 자동 복구) | 완료 | `terraform/environments/gcp/mig.tf` |
| S-5 | Terraform 변수화 및 Environment 분리 | 완료 | [ADR-003](../architecture/adr/003-terraform-variable-structure.md) |
| S-6 | Troubleshooting 문서화 | 완료 | [Troubleshooting](../04-troubleshooting/README.md) |

## Could Have (선택)

시간이 허용되면 구현하는 요구사항.

| ID | 요구사항 | 달성 | 비고 |
|----|----------|------|------|
| C-1 | E2E 테스트 (k6, Playwright) | 완료 | `tests/e2e/`, `tests/performance/` |
| C-2 | Multi-architecture Docker Build | 완료 | `.github/workflows/ci.yml` |
| C-3 | HPA 기반 자동 Scale | 완료 | 적용됨 (CPU 70%, min 2/max 5), k6 부하 테스트 검증 완료 |
| C-4 | Alerting Rules (PagerDuty, Slack) | 미완료 | Prometheus Rules만 정의, 외부 연동 미구현 |

## Won't Have (범위 외)

현재 프로젝트 범위에서 제외하며, 향후 개선 사항으로 관리한다.

| ID | 요구사항 | 사유 |
|----|----------|------|
| W-1 | K3s Control Plane HA (Multi-Master) | 비용 및 복잡도, 단일 Master로 충분 |
| W-2 | Canary/Blue-Green Deployment | Istio 기반 구현 가능하나 범위 초과 |
| W-3 | Distributed Tracing (Jaeger/Zipkin) | Observability 확장 Phase에서 고려 |

## 요구사항-ADR 매핑

```
M-1 ← ADR-001 (GCP + K3s)
M-2 ← ADR-002 (ArgoCD GitOps)
M-4, M-5 ← ADR-007 (Monitoring Stack)
M-7 ← ADR-005 (External Secrets)
S-1 ← ADR-004 (Istio)
S-2 ← ADR-006 (Zero Trust NetworkPolicy)
S-5 ← ADR-003 (Terraform Variable Structure)
```
