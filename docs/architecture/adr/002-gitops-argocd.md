# ADR-002: ArgoCD 기반 GitOps 전략

**날짜**: 2025-12-31

---

## 상황 (Context)

Kubernetes 환경에서 Application 배포를 자동화하고, 선언적 Configuration 관리를 구현해야 한다. CI(GitHub Actions)와 CD를 분리하여 관심사를 명확히 하고, Git Repository를 Single Source of Truth로 활용하려 한다.

## 결정 (Decision)

ArgoCD를 GitOps Controller로 사용한다. K3s Bootstrap 과정에서 ArgoCD를 자동 설치하고, App of Apps 패턴으로 전체 Stack을 관리한다. ArgoCD 버전은 `v3.2.3`으로 고정하여 재현 가능한 배포를 보장한다.

## 이유 (Rationale)

| 항목 | ArgoCD | Flux CD |
|------|--------|---------|
| UI | Web UI 제공 | CLI 중심 |
| Multi-tenancy | Project 기반 분리 | Namespace 기반 |
| 학습 곡선 | 낮음 | 보통 |
| Helm 지원 | Native | Helm Controller 별도 |
| Kustomize 지원 | Native | Native |

ArgoCD는 직관적인 Web UI를 제공하여 Application Sync 상태를 시각적으로 확인할 수 있다. Monitoring-v2에서도 ArgoCD를 사용했으므로 경험을 재활용할 수 있다.

Flux CD도 좋은 선택이지만, UI 기반 모니터링과 빠른 디버깅을 위해 ArgoCD를 유지한다.

## 결과 (Consequences)

### 긍정적 측면
- Git Push만으로 Kubernetes 배포 완료 (자동 Sync)
- Application 상태를 Web UI에서 실시간 확인
- Rollback이 Git Revert로 단순화
- App of Apps 패턴으로 Stack 전체를 단일 Application으로 관리

### 부정적 측면 (Trade-offs)
- ArgoCD 자체 리소스 사용 (Memory ~300MB)
- CRD 추가로 Cluster 복잡도 증가
- Secret 관리를 위해 별도 솔루션(Sealed Secrets, External Secrets 등) 필요
