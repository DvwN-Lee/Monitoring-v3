# Implementation Summary

Phase별 구현 상세, 기술적 의사결정, 발생 이슈 및 해결 방법을 정리한다.

## 기술 스택 버전

| 계층 | 기술 | 버전 |
|------|------|------|
| Cloud Provider | Google Cloud Platform | - |
| IaC | Terraform | >= 1.5.0 |
| Terraform Google Provider | hashicorp/google | v5.44+ |
| Kubernetes | K3s | v1.31.4+k3s1 |
| Service Mesh | Istio | v1.24.2 |
| GitOps | ArgoCD | Latest (Helm) |
| Prometheus Stack | kube-prometheus-stack | Helm Chart |
| Log Aggregation | Loki + Promtail | v2.9.3 |
| Dashboard | Grafana | Helm Chart |
| Service Mesh Dashboard | Kiali | v2.4.0 |
| Secret Management | External Secrets Operator | Helm Chart |
| API Gateway | Go (net/http) | Go 1.24 |
| Backend Services | Python FastAPI | Python 3.11 |
| Database | PostgreSQL | 15 |
| Cache | Redis | 7 |
| CI/CD | GitHub Actions | - |
| Load Testing | k6 | - |
| Browser Testing | Playwright | v1.57+ |
| Infrastructure Testing | Terratest (Go) | Go 1.24 |
| OS | Ubuntu | 22.04 LTS |

## Phase 1: Infrastructure 기반 구축

**기간**: 2025-12-18 ~ 12-25

### 주요 구현

**GCP Terraform Infrastructure**
- VPC Network, Subnet (10.128.0.0/20), Firewall Rules 정의
- Compute Instance: Master(e2-medium) + Worker(e2-standard-2) x 2
- Service Account: logging, monitoring Role
- MIG (Managed Instance Group) 기반 Worker Node Auto-healing

**K3s Bootstrap 자동화**
- `k3s-server.sh`: Master Node에 K3s 설치, ArgoCD Helm 설치, Root App 등록
- `k3s-agent.sh`: Worker Node가 Master에 Join
- 단일 `terraform apply`로 VM 생성 → K3s 설치 → ArgoCD → Application 배포까지 완료

**ArgoCD App of Apps 구조**
- `apps/root-app.yaml`: 진입점, automated sync + prune + selfHeal
- `apps/infrastructure/`: Istio, Prometheus, Loki, Kiali, External Secrets
- `apps/applications/`: titanium-prod (4 Microservices + PostgreSQL + Redis)

### 기술적 의사결정

- K3s 선택: 단일 Binary로 Bootstrap 빠름, Rancher 생태계 호환 ([ADR-001](../architecture/adr/001-gcp-k3s-infrastructure.md))
- ArgoCD App of Apps: 선언적 구조로 Infrastructure/Application 분리 관리 ([ADR-002](../architecture/adr/002-gitops-argocd.md))
- Terraform 변수화: Environment별 분리 가능한 구조 ([ADR-003](../architecture/adr/003-terraform-variable-structure.md))

## Phase 2: Security 강화

**기간**: 2025-12-28 ~ 2026-01-05

### 주요 구현

- GCP Firewall CIDR Validation 추가, `0.0.0.0/0` 차단
- CORS wildcard 제거, 특정 Domain 제한으로 변경
- API Gateway Security Headers: HSTS, X-Frame-Options, CSP, X-Content-Type-Options
- Rate Limiting 적용 (per IP)
- HTTPS/TLS 인증서 자동 생성 (Bootstrap Script)
- JWT RS256 인증 (RSA 2048 Key Pair)

### 발생 이슈

- Backend Critical Security 취약점 (PR #19): SQL Injection 방어, Input Validation 강화
- Terraform Firewall CIDR validation (PR #18): `0.0.0.0/0` 허용 시 에러 발생하도록 변경

## Phase 3: Testing 자동화

**기간**: 2026-01-06 ~ 01-16

### 주요 구현

**Terratest (Infrastructure Testing)**

| Layer | 테스트 | 비용 | 시간 |
|-------|--------|------|------|
| 0 | Static Validation (format, syntax) | $0 | < 1분 |
| 1 | Plan Unit Tests (리소스 구성 검증) | $0 | < 3분 |
| 1.5 | Plan Deep Analysis (12개 Subtest: ResourceCount, FirewallTargetTags, IAMRoles 등) | $0 | < 3분 |
| 2 | Network Layer (VPC, Subnet, Firewall) | 낮음 | < 5분 |
| 3 | Compute & K3s (VM, SSH, K3s, 멱등성) | 중간 | 5-6분 |
| 4 | Full Integration (E2E, ArgoCD, Monitoring) | 높음 | 6분 |
| 5 | Monitoring Stack (Prometheus, Grafana, Loki 검증) | 높음 | 6분+ |

**코드 레벨 단위 테스트**
- Python Services: pytest 기반 (auth-service, user-service, blog-service)
- Go API Gateway: go test 기반

### 발생 이슈

- Terratest 관련 8건의 문제 발생 및 해결 ([Testing Troubleshooting](../04-troubleshooting/testing/README.md))
- ArgoCD `Degraded` 상태에서도 Application이 동작하는 `Functionally Ready` 패턴 도입

## Phase 4: Service Mesh + Secret Management

**기간**: 2026-01-17 ~ 01-31

### 주요 구현

**Istio Service Mesh 정책 공식화**
- PeerAuthentication: STRICT mTLS 전체 Namespace 검증 완료 (초기 적용은 Phase 1, 2025-12-29)
- DestinationRule: Service별 트래픽 정책
- VirtualService: Istio IngressGateway 기반 라우팅 (7개 규칙)
- Gateway: HTTP/HTTPS 진입점

**Zero Trust NetworkPolicy**
- Default Deny (Ingress + Egress)
- Explicit Allow: Service 간 필요한 통신만 허용
- Pod Label 기반 세밀한 접근 제어

**External Secrets + GCP Secret Manager**
- ClusterSecretStore: GCE ADC 인증 (SA Key JSON 불필요)
- ExternalSecret: 7개 Secret 자동 동기화
- Sync Wave를 통한 배포 순서 보장 (-5 → -1 → 0 → 1)

### 기술적 의사결정

- Istio 단계적 도입: Gateway → mTLS → NetworkPolicy 순서 ([ADR-004](../architecture/adr/004-istio-service-mesh.md))
- GCE ADC 인증: SA Key JSON 관리 부담 제거 ([ADR-005](../architecture/adr/005-external-secrets-gcp.md))
- Zero Trust: Default Deny 우선 적용 ([ADR-006](../architecture/adr/006-zero-trust-networkpolicy.md))

## Phase 5: Production 안정화

**기간**: 2026-02-01 ~ 02-10

### 주요 구현

- IaC 배포 문제 10건 해결 및 문서화 ([Troubleshooting](../04-troubleshooting/README.md))
- Kiali multi-cluster 자동 감지 비활성화 (single-cluster 최적화)
- Terraform Hybrid IP 관리 방식 전환
- 문서-코드 정합성 전면 검증 및 수정
- Demo 검증 및 스크린샷 23종 작성

### 주요 해결 이슈

| 이슈 | 원인 | 해결 |
|------|------|------|
| PostgreSQL Password Race Condition | ExternalSecret 타이밍 | Sync Wave 도입 |
| Istio Gateway Sidecar Injection | Webhook 미등록 시점 Pod 생성 | 자동 재시작 로직 |
| ESO CRD/Webhook 오류 | CRD 미설치 | `installCRDs: true` |
| ArgoCD PVC Health Check | WaitForFirstConsumer | Custom Lua Script |

## 관련 문서

- [Project Plan](../01-planning/project-plan.md)
- [Requirements](../01-planning/requirements.md)
- [Architecture](../architecture/README.md)
- [ADR Index](../architecture/adr/README.md)
