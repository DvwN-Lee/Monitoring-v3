# Architecture Decision Records (ADR)

프로젝트의 주요 아키텍처 결정을 문서화한다.

## ADR 목록

| ADR | 제목 | 날짜 | 상태 |
|-----|------|------|------|
| [ADR-001](001-gcp-k3s-infrastructure.md) | GCP + K3s 기반 Infrastructure 선택 | 2025-12-31 | Accepted |
| [ADR-002](002-gitops-argocd.md) | ArgoCD 기반 GitOps 전략 | 2025-12-31 | Accepted |
| [ADR-003](003-terraform-variable-structure.md) | Terraform 변수화 및 Environment 분리 구조 | 2025-12-31 | Accepted |
| [ADR-004](004-istio-service-mesh.md) | Istio Service Mesh 도입 | 2026-01-15 | Accepted |
| [ADR-005](005-external-secrets-gcp.md) | External Secrets + GCP Secret Manager | 2026-01-20 | Accepted |
| [ADR-006](006-zero-trust-networkpolicy.md) | Zero Trust NetworkPolicy 모델 | 2026-01-25 | Accepted |
| [ADR-007](007-monitoring-stack.md) | Monitoring Stack (Prometheus + Loki + Grafana) | 2026-01-10 | Accepted |

## ADR 상태 정의

- **Proposed**: 검토 중
- **Accepted**: 승인됨, 적용 중
- **Deprecated**: 더 이상 유효하지 않음
- **Superseded**: 다른 ADR로 대체됨

## 새 ADR 작성

[template.md](template.md) 파일을 복사하여 작성한다.

```bash
cp template.md NNN-title.md
```

파일명 규칙: `NNN-kebab-case-title.md`
