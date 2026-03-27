# Performance

성능 요구사항 정의 및 테스트 결과를 정리한다.

## 성능 목표

| Metric | 목표 | 측정 도구 |
|--------|------|----------|
| HTTP Response Time (P95) | < 500ms | k6 |
| HTTP Error Rate | < 1% | k6 |
| Check Pass Rate | > 99% | k6 |
| Health Check Response | < 200ms | k6 |
| Cluster CPU Utilisation | < 70% | Prometheus/Grafana |
| Cluster Memory Utilisation | < 80% | Prometheus/Grafana |

## 테스트 전략

### 부하 테스트 (k6)

단계별 부하를 증가시켜 시스템의 처리 한계를 확인한다.

| 단계 | 시간 | 동시 사용자 | 목적 |
|------|------|------------|------|
| Ramp-up 1 | 1분 | 0 → 10 | 시스템 워밍업 |
| Steady 1 | 2분 | 10 | 기본 부하 안정성 |
| Ramp-up 2 | 1분 | 10 → 50 | 부하 증가 |
| Steady 2 | 2분 | 50 | 중간 부하 안정성 |
| Ramp-up 3 | 1분 | 50 → 100 | 최대 부하 |
| Steady 3 | 2분 | 100 | 고부하 안정성 |
| Ramp-down | 1분 | 100 → 0 | 복구 |

테스트 대상 Endpoint:

| Endpoint | 기대 응답 | 응답 시간 목표 |
|----------|----------|--------------|
| `/` (Dashboard) | 200 | < 1000ms |
| `/blog/` (Blog Main) | 200 | < 1000ms |
| `/blog/api/posts` (API) | 200 | < 500ms |
| `/health` (Health Check) | 200 | < 200ms |

### E2E 테스트 (k6)

단일 사용자의 전체 User Journey를 시뮬레이션한다.

- Scenario 1: 비인증 사용자 (Blog 조회, 게시글 목록, 권한 없는 쓰기 시도)
- Scenario 2: 인증 사용자 (회원가입, 로그인, CRUD 전체 흐름)

### Browser 테스트 (Playwright)

Grafana Dashboard 렌더링 및 UI 기능을 검증한다.

## 테스트 실행 방법

```bash
# k6 부하 테스트
k6 run tests/performance/load-test.js -e BASE_URL=http://<MASTER_IP>:31080

# k6 E2E 테스트
k6 run tests/e2e/e2e-test.js -e BASE_URL=http://<MASTER_IP>:31080

# Playwright Browser 테스트
npx playwright test tests/browser/
```

## 문서 목록

| 문서 | 설명 |
|------|------|
| [부하 테스트 결과](load-test-results.md) | k6 부하 테스트 시나리오 및 결과 |
| [리소스 사용량 분석](resource-usage-analysis.md) | CPU/Memory 사용량 분석 |

## 관련 파일

- `tests/performance/load-test.js`: k6 부하 테스트 Script
- `tests/performance/quick-test.js`: 간단 Smoke 테스트
- `tests/e2e/e2e-test.js`: E2E User Journey 테스트
- `tests/browser/dashboard-test.spec.ts`: Playwright Browser 테스트
