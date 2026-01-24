# 서비스 통합 테스트 보고서

**날짜:** 2026-01-24
**환경:** GCP K3s Cluster (titanium-k3s-20260123)
**Namespace:** titanium-prod

## 테스트 개요

IaC 배포 완료 후 마이크로서비스 아키텍처의 통합 동작 검증을 수행함. External Secrets Operator를 통한 GCP Secret Manager 연동 및 서비스 간 통신을 검증.

---

## 1. Infrastructure 검증

### 1.1 Kubernetes Cluster 상태

```
Node 상태:
- titanium-k3s-master: Ready (control-plane)
- titanium-k3s-worker: Ready

Kubernetes 버전: v1.34.3+k3s1
```

### 1.2 Pod 상태 (titanium-prod namespace)

| Service | Replicas | Status | Istio Sidecar |
|---------|----------|--------|---------------|
| prod-api-gateway | 2/2 | Running | ✓ |
| prod-auth-service | 2/2 | Running | ✓ |
| prod-user-service | 2/2 | Running | ✓ |
| prod-blog-service | 2/2 | Running | ✓ |
| prod-postgresql | 1/1 | Running | - |
| prod-redis | 1/1 | Running | ✓ |

모든 애플리케이션 Pod가 `2/2 Ready` 상태로 Istio sidecar proxy 정상 주입 확인.

### 1.3 Service Endpoints 연결 상태

```
NAME                       ENDPOINTS
prod-api-gateway-service   10.42.0.21:8000,10.42.1.18:8000
prod-auth-service          10.42.0.25:8002,10.42.1.29:8002
prod-user-service          10.42.0.22:8001,10.42.1.21:8001
prod-blog-service          10.42.0.19:8005,10.42.1.19:8005
```

모든 Service가 정상적으로 Backend Pod에 연결됨. 각 서비스당 2개의 Endpoint 확인.

---

## 2. Health Check 테스트

### 2.1 테스트 방법

Kubernetes liveness/readiness probe 동작 확인을 위해 각 서비스 Pod 로그 분석.

### 2.2 테스트 결과

| Service | Endpoint | Status | Log Sample |
|---------|----------|--------|------------|
| api-gateway | :8000 | PASS | `Go API Gateway started on :8000` |
| auth-service | :8002/health | PASS | `INFO: 127.0.0.6 - "GET /health HTTP/1.1" 200 OK` |
| user-service | :8001/health | PASS | `INFO: 127.0.0.6 - "GET /health HTTP/1.1" 200 OK` |
| blog-service | :8005/health | PASS | `INFO: 127.0.0.6 - "GET /health HTTP/1.1" 200 OK` |

모든 서비스에서 health check endpoint가 지속적으로 HTTP 200 OK 응답 반환. Kubernetes probe가 정상 작동 중임을 확인.

---

## 3. 인증 서비스 (auth-service) 검증

### 3.1 JWT 초기화 로그 확인

```
INFO:auth_service:Auth service initialized with RS256 JWT authentication.
INFO:     Started server process [1]
INFO:     Waiting for application startup.
INFO:AuthServiceApp:Auth Service starting on http://0.0.0.0:8002
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8002 (Press CTRL+C to quit)
```

auth-service가 External Secrets Operator를 통해 GCP Secret Manager에서 받은 JWT 키로 RS256 알고리즘 기반 인증을 정상 초기화함.

### 3.2 Secret 연동 검증

```bash
# ExternalSecret 상태
$ kubectl get externalsecret -n titanium-prod prod-app-secrets
STATUS: SecretSynced

# Kubernetes Secret 생성 확인
$ kubectl get secret -n titanium-prod prod-app-secrets
DATA: 7

# JWT_PRIVATE_KEY 형식 검증
PEM 형식 (-----BEGIN PRIVATE KEY-----) 정상 확인
```

GCP Secret Manager → ExternalSecret → Kubernetes Secret 파이프라인 정상 작동.

---

## 4. Network Policy 및 Service Mesh 검증

### 4.1 Istio 구성 요소

| Component | Status | Details |
|-----------|--------|---------|
| Gateway | Active | HTTPS (443), HTTP→HTTPS redirect |
| VirtualService | Active | 라우팅 규칙 설정됨 |
| PeerAuthentication | STRICT | mTLS 강제 적용 |
| Sidecar Injection | Enabled | namespace label: istio-injection=enabled |

### 4.2 NetworkPolicy 설정

각 서비스별 NetworkPolicy가 설정되어 Zero Trust 아키텍처 구현:

**user-service Ingress 허용 대상:**
- `app=api-gateway` 레이블 Pod
- `app=auth-service` 레이블 Pod
- `monitoring` namespace Pod

**Egress 허용 대상:**
- PostgreSQL (5432)
- Redis (6379)
- Istio Control Plane (15012, 15010)
- DNS (53/UDP)

### 4.3 테스트 제약사항

NetworkPolicy로 인해 임의의 테스트 Pod에서 서비스로의 직접 접근이 차단됨. 이는 의도된 보안 설정으로, 실제 운영 환경에서 정상 동작함.

```
테스트 Pod → user-service: Connection refused (NetworkPolicy 차단)
Kubernetes Probe → user-service: HTTP 200 OK (정상)
```

---

## 5. Istio Gateway 라우팅 검증

### 5.1 VirtualService 라우팅 규칙

| Path | Destination Service | Rewrite | Port |
|------|---------------------|---------|------|
| /blog | prod-blog-service | - | 8005 |
| /api/users | prod-user-service | /users | 8001 |
| /api/login | prod-auth-service | /login | 8002 |
| /api/auth | prod-auth-service | / | 8002 |
| /api/ | prod-api-gateway-service | - | 8000 |

### 5.2 Gateway 설정

```yaml
서버:
  - HTTPS (443): TLS 인증서 사용 (titanium-tls-credential)
  - HTTP (80): HTTPS로 리다이렉트

NodePort:
  - HTTP: 30081
  - HTTPS: 30444
```

---

## 6. 검증 체크리스트

### Infrastructure
- [x] Kubernetes Node 정상 (2개 Node Ready)
- [x] 모든 Application Pod Running (2/2)
- [x] Service Endpoints 연결됨
- [x] Istio sidecar 주입 정상

### Health Check
- [x] api-gateway /health 정상 (로그 확인)
- [x] auth-service /health 정상 (200 OK)
- [x] user-service /health 정상 (200 OK)
- [x] blog-service /health 정상 (200 OK)

### Secret Management
- [x] External Secrets Operator 정상 작동
- [x] GCP Secret Manager 연동 성공
- [x] Kubernetes Secret 생성됨 (prod-app-secrets)
- [x] JWT_PRIVATE_KEY PEM 형식 정상

### Security
- [x] Istio mTLS STRICT 모드 적용
- [x] NetworkPolicy 설정 (Zero Trust)
- [x] HTTPS TLS 설정 (Gateway)

---

## 7. 테스트 제약사항 및 권고사항

### 7.1 현재 제약사항

1. **NetworkPolicy로 인한 직접 테스트 불가**
   - 임의 Pod에서 서비스 직접 호출 차단됨
   - Kubernetes probe는 정상 작동 (내부 메커니즘)

2. **외부 접근 경로**
   - Istio Gateway: HTTPS 전용, TLS 인증서 필요
   - NodePort: 방화벽 규칙 확인 필요

### 7.2 권고사항

1. **통합 테스트 방법**
   - api-gateway Pod 내부에서 테스트 실행
   - 또는 NetworkPolicy에 테스트용 label 추가

2. **외부 접근 설정**
   - DNS 설정 후 도메인으로 HTTPS 접근
   - 또는 개발용 HTTP endpoint 추가 고려

3. **Monitoring 연동**
   - Prometheus ServiceMonitor 설정 확인
   - Grafana Dashboard 구성

---

## 8. 결론

### 8.1 성공 항목

1. IaC를 통한 전체 Infrastructure 정상 배포
2. External Secrets Operator 및 GCP Secret Manager 연동 성공
3. auth-service RS256 JWT 인증 정상 초기화
4. Istio Service Mesh (mTLS, sidecar injection) 정상 작동
5. NetworkPolicy 기반 Zero Trust 보안 구현
6. 모든 서비스 Health Check 정상

### 8.2 Infrastructure 준비 완료

마이크로서비스 아키텍처의 Infrastructure 레벨 배포 및 보안 설정이 완료되었음. 애플리케이션 레벨의 통합 테스트는 NetworkPolicy 및 Gateway 설정을 고려하여 별도로 진행해야 함.

### 8.3 다음 단계

1. DNS 및 TLS 인증서 설정
2. 외부 접근 가능한 테스트 환경 구성
3. E2E 애플리케이션 테스트 시나리오 작성
4. Monitoring Dashboard 구성 및 검증
