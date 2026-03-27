# Load Test Results

k6 기반 부하 테스트 시나리오 및 결과를 정리한다.

## 테스트 환경

| 항목 | 값 |
|------|-----|
| Cluster | GCP K3s v1.31.4+k3s1 |
| Master Node | e2-medium (2 vCPU, 4GB RAM) |
| Worker Node | e2-standard-2 (2 vCPU, 8GB RAM) x 2 |
| Service Mesh | Istio v1.24.2 (mTLS STRICT) |
| 테스트 도구 | k6 |

## 부하 테스트 시나리오

### 테스트 구성

```javascript
export const options = {
  stages: [
    { duration: '1m', target: 10 },    // Ramp-up
    { duration: '2m', target: 10 },    // Steady (10 VUs)
    { duration: '1m', target: 50 },    // Ramp-up
    { duration: '2m', target: 50 },    // Steady (50 VUs)
    { duration: '1m', target: 100 },   // Ramp-up
    { duration: '2m', target: 100 },   // Steady (100 VUs)
    { duration: '1m', target: 0 },     // Ramp-down
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'],   // P95 < 500ms
    http_req_failed: ['rate<0.01'],     // Error Rate < 1%
    checks: ['rate>0.99'],             // Check Pass > 99%
  },
};
```

### 테스트 대상

| # | Endpoint | Method | 검증 항목 |
|---|----------|--------|----------|
| 1 | `/` | GET | Status 200, 응답 시간 < 1s |
| 2 | `/blog/` | GET | Status 200, 응답 시간 < 1s |
| 3 | `/blog/api/posts` | GET | Status 200, 응답 시간 < 500ms |
| 4 | `/health` | GET | Status 200, 응답 시간 < 200ms |

### 실행 방법

```bash
# 기본 실행
k6 run tests/performance/load-test.js -e BASE_URL=http://<MASTER_IP>:31080

# 결과 Summary를 JSON으로 저장
k6 run tests/performance/load-test.js -e BASE_URL=http://<MASTER_IP>:31080 \
  --summary-export=tests/performance/results.json
```

### Threshold 정의

| Metric | 조건 | 설명 |
|--------|------|------|
| `http_req_duration` | P95 < 500ms | 95% 요청의 응답 시간이 500ms 미만 |
| `http_req_failed` | Rate < 1% | HTTP 에러율 1% 미만 |
| `checks` | Rate > 99% | 99% 이상의 검증 항목 통과 |

## E2E 테스트 시나리오

### 테스트 구성

```javascript
export const options = {
  vus: 1,
  iterations: 1,
  thresholds: {
    checks: ['rate>0.9'],
  },
};
```

### Scenario 1: 비인증 사용자

| # | 테스트 | 기대 결과 |
|---|--------|----------|
| 1.1 | Blog Main Page | 200 |
| 1.2 | Posts List API | 200, Array 반환 |
| 1.3 | Categories API | 200 |
| 1.4 | 비인증 게시글 작성 | 401 (Unauthorized) |

### Scenario 2: 인증 사용자

| # | 테스트 | 기대 결과 |
|---|--------|----------|
| 2.1 | 회원가입 | 201 |
| 2.2 | 로그인 | 200, JWT Token 반환 |
| 2.3 | 게시글 작성 | 201, Post ID 반환 |
| 2.4 | 게시글 조회 | 200, 제목 일치 |
| 2.5 | 게시글 수정 | 200 |
| 2.6 | 게시글 삭제 | 204 |
| 2.7 | 삭제 확인 | 404 |

### 실행 방법

```bash
k6 run tests/e2e/e2e-test.js -e BASE_URL=http://<MASTER_IP>:31080
```

## 부하 테스트 결과

`tests/performance/results.json` 기준 (100 VUs, 약 10분).

### Threshold 결과

| Threshold | 조건 | 결과 | 판정 |
|-----------|------|------|------|
| `http_req_duration` | P95 < 500ms | **74.76ms** | PASS |
| `http_req_failed` | Rate < 1% | **0.011%** (3/28,020) | PASS |
| `checks` | Rate > 99% | **99.95%** (56,011/56,040) | PASS |

### HTTP 응답 시간 상세 (`http_req_duration`)

| Metric | 값 |
|--------|-----|
| avg | 33.86ms |
| med | 25.01ms |
| min | 10.97ms |
| max | 577.66ms |
| p(90) | 55.67ms |
| p(95) | 74.76ms |

### Check 항목별 결과

| Check | Pass | Fail |
|-------|------|------|
| dashboard status 200 | 7,005 | 0 |
| dashboard response time < 1s | 7,005 | 0 |
| blog status 200 | 7,005 | 0 |
| blog response time < 1s | 7,005 | 0 |
| blog api status 200 | 7,004 | 1 |
| blog api response time < 500ms | 7,005 | 0 |
| health status 200 | 7,003 | 2 |
| health response time < 200ms | 6,979 | 26 |

### 요약

- 총 28,020 HTTP 요청 처리, 평균 46.49 req/s
- 전체 테스트 시간: 약 603초 (10분)
- 최대 동시 사용자: 100 VUs
- **모든 Threshold 통과**

## Quick Test 결과

`tests/performance/quick-results.json` 기준 (10 VUs, 약 2분).

| Threshold | 조건 | 결과 | 판정 |
|-----------|------|------|------|
| `http_req_duration` | P95 < 500ms | **95.92ms** | PASS |
| `http_req_failed` | Rate < 1% | **0%** (0/876) | PASS |
| `checks` | Rate > 99% | **99.89%** (1,750/1,752) | PASS |

- 총 876 HTTP 요청, 평균 7.29 req/s
- HTTP 응답 시간: avg=67.20ms, med=63.95ms, p90=81.82ms, p95=95.92ms

## 결과 분석 방법

### k6 출력 Metrics 해석

| Metric | 설명 |
|--------|------|
| `http_req_duration` | 전체 HTTP Request 소요 시간 |
| `http_req_blocked` | TCP Connection 대기 시간 |
| `http_req_connecting` | TCP Connection 수립 시간 |
| `http_req_tls_handshaking` | TLS Handshake 시간 |
| `http_req_sending` | Request Body 전송 시간 |
| `http_req_waiting` | Server 응답 대기 시간 (TTFB) |
| `http_req_receiving` | Response Body 수신 시간 |

### Grafana에서 테스트 결과 확인

부하 테스트 중 Grafana Dashboard에서 실시간 Metrics 변화를 모니터링한다.

```promql
# HTTP Request Rate 변화
sum(rate(istio_requests_total{destination_service_namespace="titanium-prod"}[1m])) by (destination_service_name)

# P95 Latency 변화
histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{destination_service_namespace="titanium-prod"}[1m])) by (le, destination_service_name))

# Error Rate 변화
sum(rate(istio_requests_total{destination_service_namespace="titanium-prod", response_code=~"5.."}[1m])) / sum(rate(istio_requests_total{destination_service_namespace="titanium-prod"}[1m]))
```
