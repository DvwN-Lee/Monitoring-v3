# Top-Down 전체 서비스 테스트 시스템

Monitoring-v3 프로젝트의 모든 Service를 Top-Down 방식으로 검증하는 종합 테스트 시스템입니다.

## 테스트 레벨 구조

```
Level 1: E2E (사용자 시나리오)           - 전체 사용자 여정 검증
    ↓
Level 2: Integration (Service 간 통신)    - Istio 라우팅, mTLS
    ↓
Level 3: Individual Service (개별 API)   - 각 Service Endpoint
    ↓
Level 4: Infrastructure (인프라 상태)    - Kubernetes, Istio, 모니터링
```

**실행 순서**: Level 4 → Level 3 → Level 2 → Level 1

인프라가 정상이어야 Service가 작동하고, Service가 정상이어야 통합 및 E2E 테스트가 의미 있습니다.

---

## 빠른 시작

### 전체 테스트 실행

```bash
cd tests
./run-all-tests.sh
```

### 특정 레벨만 실행

```bash
# Level 4: Infrastructure
./infrastructure/k8s-test.sh
./infrastructure/istio-test.sh
./infrastructure/monitoring-test.sh
./infrastructure/gitops-test.sh

# Level 3: Individual Services
./smoke/api-gateway-test.sh
./smoke/auth-service-test.sh
./smoke/user-service-test.sh
./smoke/blog-service-test.sh
./smoke/database-test.sh

# Level 2: Integration
./integration/routing-test.sh
./integration/mtls-test.sh

# Level 1: E2E
k6 run e2e/e2e-test.js
```

---

## 테스트 결과

테스트 실행 후 `test-results.json` 파일에 상세 결과가 저장됩니다.

### JSON 리포트 예시

```json
{
  "timestamp": "2024-12-05T12:00:00Z",
  "summary": {
    "total": 50,
    "passed": 48,
    "failed": 2,
    "pass_rate": "96.0%"
  },
  "levels": {
    "level4_infrastructure": { "passed": 15, "failed": 0 },
    "level3_services": { "passed": 20, "failed": 1 },
    "level2_integration": { "passed": 8, "failed": 0 },
    "level1_e2e": { "passed": 5, "failed": 1 }
  },
  "details": [...]
}
```

---

## Level 4: Infrastructure Tests

### k8s-test.sh
Kubernetes 리소스 상태 검증
- Node 상태 (Ready)
- Namespaces (titanium-prod, monitoring, istio-system, argocd)
- Application Pods (Running)
- PostgreSQL, Redis Pods
- PVC 상태 (Bound)
- HPA 설정

### istio-test.sh
Istio Service Mesh 리소스 검증
- Istio Ingress Gateway
- Gateway, VirtualService, DestinationRule
- PeerAuthentication (STRICT mode)

### monitoring-test.sh
모니터링 스택 검증
- Prometheus Pod + API
- Grafana Pod
- Loki Pod
- ServiceMonitor 개수

### gitops-test.sh
Argo CD GitOps 상태 검증
- Argo CD Pods
- Application Health (Healthy)
- Sync Status (Synced)
- Auto Sync Policy

---

## Level 3: Individual Service Tests

### api-gateway-test.sh
- `/health` - Health Check
- `/metrics` - Prometheus 메트릭
- `/stats` - Service Status

### auth-service-test.sh
- `/health` - Health Check
- `/metrics` - Prometheus 메트릭
- `/stats` - 서비스 통계
- `/login` - 로그인 (401 검증)

### user-service-test.sh
- `/health` - Health Check
- `/metrics` - Prometheus 메트릭
- `/stats` - DB 상태 포함

### blog-service-test.sh
- `/health` - Health Check
- `/metrics` - Prometheus 메트릭
- `/blog/api/posts` - 게시물 목록
- `/blog/api/categories` - 카테고리 목록
- `/blog/` - 웹 UI

### database-test.sh
- PostgreSQL 연결 테스트 (`SELECT 1`)
- PostgreSQL 테이블 확인
- Redis 연결 테스트 (`PING`)

---

## Level 2: Integration Tests

### routing-test.sh
Istio Gateway를 통한 라우팅 검증
- `/` → Blog Service
- `/blog/` → Blog Service
- `/blog/api/posts` → Blog Service
- `/api/login` → Auth Service

### mtls-test.sh
mTLS 설정 검증
- PeerAuthentication STRICT mode
- Istio Sidecar Injection (2/2)
- Istio Proxy 설정

---

## Level 1: E2E Tests

### e2e-test.js (k6)
전체 사용자 여정 시나리오

#### Scenario 1: 비인증 사용자
- Blog 메인 페이지 접근
- 게시물 목록 조회
- 카테고리 조회
- 미인증 글 작성 시도 (401 검증)

#### Scenario 2: 인증 사용자
- 사용자 등록
- 로그인 (JWT Token 획득)
- 글 작성
- 글 조회
- 글 수정
- 글 삭제
- 삭제 확인 (404 검증)

---

## 성공 기준

| Level | 필수 통과율 | 실행 시점 |
|-------|-------------|-----------|
| Level 4 | 100% | 배포 전/장애 발생 시 |
| Level 3 | 100% (Health), 95% (API) | 배포 후/Daily |
| Level 2 | 95% | 설정 변경 시 |
| Level 1 | 90% | 릴리스 전/Weekly |

**참고**: Level 4가 100% 통과하지 못하면 상위 레벨 테스트는 실행되지 않습니다.

---

## 사전 요구사항

### Kubernetes Cluster
- kubectl 설정 완료
- Cluster 접근 권한

### k6 설치 (Level 1 E2E 테스트)
```bash
# macOS
brew install k6

# Linux
sudo apt-get install k6

# 설치 확인
k6 version
```

### 환경 변수 (선택사항)
```bash
# E2E 테스트 Base URL 변경
export BASE_URL="http://your-ingress-ip"
k6 run tests/e2e/e2e-test.js
```

---

## 트러블슈팅

### kubectl 연결 실패
```bash
# Kubeconfig 확인
kubectl config current-context

# Context 전환
kubectl config use-context <your-context>
```

### Pod 실행 실패 (test-curl)
테스트 스크립트는 일시적인 Pod를 생성하여 내부 Service DNS로 접근합니다.
Pod 생성 권한이 필요합니다.

### k6 설치되지 않음
Level 1 E2E 테스트는 k6가 필요합니다. k6 없이도 Level 2-4 테스트는 실행 가능합니다.

---

## CI/CD 통합

### GitHub Actions 예시
```yaml
- name: Run Top-Down Tests
  run: |
    cd tests
    ./run-all-tests.sh

- name: Upload Test Results
  uses: actions/upload-artifact@v2
  with:
    name: test-results
    path: tests/test-results.json
```

---

## 기여

테스트 추가 또는 개선 시 다음 규칙을 따라주세요:

1. 각 테스트는 독립적으로 실행 가능해야 합니다
2. 테스트 실패 시 명확한 에러 메시지를 제공해야 합니다
3. 새로운 서비스 추가 시 해당 레벨에 테스트를 추가해야 합니다

---

## 라이선스

이 테스트 시스템은 Monitoring-v3 프로젝트의 일부입니다.
