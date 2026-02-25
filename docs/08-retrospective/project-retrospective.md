# Project Retrospective

## 정량적 성과

### 프로젝트 규모

| 항목 | 수치 |
|------|------|
| 개발 기간 | 약 8주 (2025-12-18 ~ 2026-02-10) |
| 총 커밋 수 | 676 |
| Pull Request | 99+ |
| Merged PR | 주요 기능/수정 PR 다수 |
| ADR 문서 | 10개 (ADR-001 ~ ADR-010) |
| Troubleshooting 문서 | 19건 |

### 기술 스택 구성

| 영역 | 수치 |
|------|------|
| Terraform 리소스 | VPC, Subnet, Firewall, Compute Instance, SA, MIG 등 |
| Kubernetes Namespace | 5개 (argocd, istio-system, monitoring, titanium-prod, external-secrets) |
| ArgoCD Application | 9개 |
| Microservice | 4개 (api-gateway, auth, user, blog) |
| Terratest Layer | 7개 (Layer 0~5 + Layer 1.5), 7개 테스트 파일 + helpers 총 4,327줄 |
| Istio 리소스 | Gateway, VirtualService, DestinationRule, PeerAuthentication, AuthorizationPolicy |
| NetworkPolicy | Default Deny + Service별 Explicit Allow |

### Infrastructure 효율성

| Metric | 값 |
|--------|-----|
| 전체 배포 소요 시간 | 약 10분 (`terraform apply` 이후) |
| Cluster CPU Utilisation | 10.8% |
| Cluster Memory Utilisation | 30.3% |
| Node 구성 | 1 Master (e2-medium) + 2 Workers (e2-standard-2) |

## What Went Well

### End-to-End 자동화 달성

단일 `terraform apply` 명령어로 GCP VM 생성부터 K3s 설치, ArgoCD 배포, Application 동기화까지 완료되는 구조를 달성했다. v2 대비 Infrastructure 자동화 범위가 Namespace 이하에서 VM + Network + Firewall 전체로 확장되었다.

### GitOps 기반 선언적 배포

ArgoCD App of Apps 패턴을 통해 Infrastructure와 Application을 계층적으로 관리한다. Git Repository가 Single Source of Truth 역할을 하며, 수동 `kubectl apply` 없이 Git Push만으로 배포가 완료된다.

### Zero Trust Security 구현

3계층 보안 모델(GCP Firewall → Kubernetes NetworkPolicy → Istio mTLS)을 적용했다. External Secrets + GCP Secret Manager를 통해 Secret 하드코딩을 완전히 제거했다.

### Troubleshooting 체계적 문서화

19건의 문제를 발생 → 원인 분석 → 해결 → 검증 형식으로 문서화했다. IaC 배포 문제 10건과 Terratest 문제 9건으로 분류하여 유사 환경에서 재발 시 참조 가능하다.

### Bottom-Up 테스트 전략

Terratest를 7개 Layer(Layer 0~5 + Layer 1.5)로 설계하여, 비용이 발생하지 않는 Static Validation/Plan Unit/Plan Deep Analysis부터 실행하고, 점진적으로 비용이 높은 Integration Test로 확장하는 구조를 채택했다.

## What Could Be Improved

### K3s Single Master 구조

현재 Master Node가 단일 구성이므로, Master 장애 시 전체 Cluster가 중단된다. Production 환경에서는 HA(High Availability) 구성이 필요하나, 비용과 복잡도를 고려하여 현재 버전에서는 제외했다.

### HPA 동작 미검증

HPA(Horizontal Pod Autoscaler)는 4개 서비스(api-gateway, auth, user, blog)에 적용되어 있으나(targetCPU 70%, min 2 / max 5), 실제 부하 테스트 환경에서 Auto-scaling 트리거 및 스케일 아웃 동작을 검증하지 못했다.

### Alerting 미구현

Prometheus Alerting Rules는 정의 가능하나, PagerDuty/Slack 등 외부 알림 채널 연동이 미구현이다. 장애 감지 시 수동 확인이 필요하다.

### Distributed Tracing 부재

Istio 기반 Metrics 및 Traffic Graph는 확인 가능하나, 개별 Request의 Service 간 흐름을 추적하는 Distributed Tracing(Jaeger/Zipkin)이 미구현이다.

### Canary/Blue-Green Deployment 미적용

Istio의 Traffic Management 기능을 활용하면 Canary/Blue-Green 배포가 가능하나, 현재는 Rolling Update만 사용한다.

## Lessons Learned

### Sync Wave의 중요성

Kubernetes 리소스 간 의존 관계가 있을 때, 생성 순서를 보장하지 않으면 Race Condition이 발생한다. ArgoCD Sync Wave(`argocd.argoproj.io/sync-wave`)를 통해 ExternalSecret → Secret → Pod 순서를 명시적으로 정의해야 한다.

- 관련 사례: [PostgreSQL Password Race Condition](../05-troubleshooting/secrets/README.md#1-postgresql-password-race-condition)

### Helm Values와 Terraform 설정의 일관성

Infrastructure를 Terraform으로, Application을 Helm으로 관리할 때, 양쪽의 Port/IP/CIDR 등 설정이 불일치하면 연결 장애가 발생한다. 설정 값의 Single Source of Truth를 정의하고 검증하는 절차가 필요하다.

- 관련 사례: [Istio Gateway NodePort 불일치](../05-troubleshooting/infrastructure/README.md#2-istio-gateway-nodeport-불일치)

### Webhook 타이밍 이슈

Kubernetes Webhook(MutatingWebhookConfiguration)이 등록되기 전에 관련 리소스가 생성되면, 예상하지 못한 상태가 된다. Bootstrap Script에 검증 및 재시도 로직을 포함해야 한다.

- 관련 사례: [Istio Gateway Sidecar Injection 실패](../05-troubleshooting/istio/README.md#5-istio-gateway-sidecar-injection-실패)

### GCP API 응답 타입 주의

GCP API가 반환하는 JSON의 필드 타입이 문서와 다를 수 있다. 특히 숫자 필드가 문자열로 반환되는 경우가 있으므로, 테스트 코드에서 타입을 유연하게 처리해야 한다.

- 관련 사례: [JSON 파싱 에러](../05-troubleshooting/testing/README.md#11-json-파싱-에러)

## 다음 단계

| 항목 | 우선순위 | 설명 |
|------|---------|------|
| K3s HA 구성 | 높음 | Multi-Master로 가용성 향상 |
| Canary Deployment | 중간 | Istio Traffic Management 기반 점진적 배포 |
| Distributed Tracing | 중간 | Jaeger/Zipkin 도입으로 Request 흐름 추적 |
| Alerting 연동 | 중간 | Slack/PagerDuty 알림 채널 연동 |
| HPA 부하 테스트 | 낮음 | 적용된 HPA(targetCPU 70%, min 2 / max 5)의 실제 스케일 아웃 동작 검증 |
| Dashboard 고도화 | 낮음 | Custom Grafana Dashboard (Golden Signals) |

## 관련 문서

- [Requirements](../01-planning/requirements.md)
- [Project Plan](../01-planning/project-plan.md)
- [Implementation Summary](../03-implementation/implementation-summary.md)
- [Troubleshooting](../05-troubleshooting/README.md)
