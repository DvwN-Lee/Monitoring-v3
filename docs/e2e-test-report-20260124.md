# E2E 테스트 리포트

## 개요

- 테스트 일자: 2026-01-24
- Cluster: titanium-k3s-20260123
- Master IP: 34.64.171.141

## 환경 설정

### Cluster 정보
| Component | IP | Zone |
|-----------|-----|------|
| Master | 34.64.171.141 | asia-northeast3-a |
| Worker | 35.216.114.119 | asia-northeast3-a |

### NodePort 매핑
| Service | NodePort | URL |
|---------|----------|-----|
| Grafana | 30300 | http://34.64.171.141:30300 |
| Prometheus | 30090 | http://34.64.171.141:30090 |
| Kiali | 31200 | http://34.64.171.141:31200 |
| Istio HTTPS Gateway | 30444 | https://34.64.171.141:30444 |

## 테스트 결과

### 1. Dashboard 테스트 (Playwright)

#### Grafana 테스트

| 테스트 | 상태 | 비고 |
|--------|------|------|
| 로그인 페이지 접근 | ✓ PASS | 스크린샷 저장 완료 |
| 로그인 및 대시보드 접근 | ✓ PASS | admin/admin 인증 성공 |
| Health API 검증 | ✓ PASS | database: ok, version: 12.2.1 |
| Datasources API (인증 필요) | ✓ PASS | 401 응답 확인 |

#### Prometheus 테스트

| 테스트 | 상태 | 비고 |
|--------|------|------|
| 모든 테스트 | ✗ FAIL | Prometheus Server 미배포 |

**원인**: kube-prometheus-stack Application이 OutOfSync 상태

**상세 오류**:
```
CustomResourceDefinition.apiextensions.k8s.io "prometheuses.monitoring.coreos.com" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

**해결 방법**: ArgoCD Application에 Server-Side Apply 설정 필요
```yaml
syncOptions:
  - ServerSideApply=true
```

#### Kiali 테스트

| 테스트 | 상태 | 비고 |
|--------|------|------|
| 모든 테스트 | - SKIP | Service 연결 타임아웃 |

**원인**: Kiali Service가 배포되지 않았거나 접근 불가

### 2. Application E2E 테스트 (K6)

#### 비인증 시나리오

| 테스트 | 상태 | HTTP 상태 | 비고 |
|--------|------|-----------|------|
| Blog 메인 페이지 | ✗ FAIL | - | Connection failed |
| Posts 목록 API | ✗ FAIL | - | Connection failed |
| Categories API | ✗ FAIL | - | Connection failed |
| 비인증 Post 생성 | ✗ FAIL | - | Connection failed |

#### 인증 시나리오

| 테스트 | 상태 | HTTP 상태 | 비고 |
|--------|------|-----------|------|
| 사용자 등록 | ✓ PASS | 201 | 정상 등록 |
| 로그인 | ✗ FAIL | - | Token 수신 실패 |
| Post 생성 | - SKIP | - | 로그인 실패로 skip |
| Post 조회 | - SKIP | - | 로그인 실패로 skip |
| Post 수정 | - SKIP | - | 로그인 실패로 skip |
| Post 삭제 | - SKIP | - | 로그인 실패로 skip |

#### 테스트 통계
```
checks_total: 8
checks_succeeded: 12.50% (1 out of 8)
checks_failed: 87.50% (7 out of 8)
http_req_failed: 83.33% (5 out of 6)
http_req_duration: avg=536ms, max=2.99s
```

**주요 오류 메시지**:
```
upstream connect error or disconnect/reset before headers.
retried and the latest reset reason: remote connection failure,
transport failure reason: delayed connect error: Connection refused
```

### 3. Infrastructure 분석

#### Pod 상태 (titanium-prod namespace)

모든 Application Pod는 Running 상태:
```
prod-api-gateway-deployment: 2/2 Running
prod-auth-service-deployment: 2/2 Running
prod-blog-service-deployment: 2/2 Running
prod-user-service-deployment: 2/2 Running
prod-postgresql: 1/1 Running
prod-redis: 2/2 Running
```

#### Service Endpoints

모든 Service에 정상적인 Endpoint가 설정됨:
```
prod-blog-service: 10.42.0.19:8005, 10.42.1.19:8005
prod-api-gateway-service: 10.42.0.21:8000, 10.42.1.18:8000
```

#### Istio Configuration

Gateway 설정:
- Selector: istio=ingressgateway (정상)
- TLS Secret: titanium-tls-credential (존재)
- HTTPS Port: 443 → NodePort 30444 (정상)

VirtualService 설정:
- Gateway 참조: prod-titanium-gateway (정상)
- 라우팅 규칙: /blog → prod-blog-service:8005 (정상)

#### mTLS Configuration

PeerAuthentication:
- prod-default-mtls: STRICT mode (모든 서비스 간 mTLS 필수)
- prod-postgresql-mtls-disable: DISABLE
- prod-redis-mtls-disable: DISABLE

DestinationRule:
- prod-default-mtls: ISTIO_MUTUAL mode

## 발견된 이슈

### Critical Issues

#### 1. kube-prometheus-stack CRD Annotation Size 제한 초과

**증상**: Prometheus Server가 배포되지 않음

**상태**:
```
Application: kube-prometheus-stack
Sync Status: OutOfSync
Health: Healthy
```

**오류**:
```
CustomResourceDefinition metadata.annotations: Too long: may not be more than 262144 bytes
```

**영향**: Prometheus 대시보드 및 메트릭 수집 불가

**해결 방안**:
1. ArgoCD Application Manifest 수정:
```yaml
spec:
  syncPolicy:
    syncOptions:
      - ServerSideApply=true
```

2. 수동 CRD 설치 후 Application Sync

#### 2. Istio Gateway → Backend Service 통신 실패

**증상**: 모든 HTTP 요청이 "upstream connect error" 발생

**확인된 사항**:
- Pod: Running 상태
- Service: Endpoints 정상
- Gateway: 설정 정상
- VirtualService: 라우팅 규칙 정상
- mTLS: STRICT mode 설정됨

**추가 조사 필요**:
- Istio Ingress Gateway와 Backend Service 간 mTLS 연결 문제 가능성
- Gateway의 실제 트래픽 로그 확인 필요
- Service Mesh 내부 통신 trace 필요

### Minor Issues

#### 3. Kiali Service 접근 불가

**증상**: 포트 31200으로 연결 타임아웃

**원인**: Kiali가 배포되지 않았거나 NodePort 설정 누락

#### 4. Firewall 규칙 IP 제한

**증상**: 최초 테스트 시 모든 서비스 연결 실패

**해결**: 현재 Public IP (221.153.70.15)를 Firewall 규칙에 추가

## 수정된 파일

### 테스트 설정 파일

1. `tests/e2e/dashboard-test.spec.ts`
   - CLUSTER_IP: 34.64.171.141
   - GRAFANA_PORT: 30300
   - PROMETHEUS_PORT: 30090

2. `tests/e2e/e2e-test.js`
   - BASE_URL: https://34.64.171.141:30444

3. `playwright.config.ts`
   - ignoreHTTPSErrors: true 추가

### Infrastructure

GCP Firewall 규칙:
```
gcloud compute firewall-rules update titanium-k3s-allow-dashboards \
  --source-ranges=112.150.249.93/32,221.153.70.15/32
```

## 권장 사항

### 즉시 조치 필요

1. kube-prometheus-stack Application 수정
   - Server-Side Apply 옵션 추가
   - Application Sync 재시도

2. Istio Gateway 통신 문제 해결
   - Istio Ingress Gateway 상세 로그 분석
   - mTLS 설정 검증
   - Service Entry 추가 고려

3. Kiali 배포
   - kiali Application 상태 확인
   - NodePort Service 설정 확인

### 개선 사항

1. Monitoring
   - Prometheus 복구 후 ServiceMonitor 확인
   - Grafana Datasource 설정 검증
   - Alert Rules 동작 확인

2. E2E Testing
   - Istio 문제 해결 후 테스트 재실행
   - 전체 User Journey 검증
   - 성능 메트릭 수집

3. Security
   - Firewall 규칙 IP 범위 검토
   - TLS Certificate 갱신 주기 확인
   - mTLS Policy 최적화

## 다음 단계

1. kube-prometheus-stack 수정 및 배포
2. Istio Gateway 통신 문제 디버깅
3. 수정 후 E2E 테스트 재실행
4. 전체 Monitoring Stack 검증
5. 운영 환경 배포 가이드 작성
