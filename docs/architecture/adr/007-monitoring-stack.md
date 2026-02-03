# ADR-007: Monitoring Stack (Prometheus + Loki + Grafana)

**날짜**: 2026-01-10

---

## 상황 (Context)

Microservice 환경에서 다음 관측성(Observability) 요구사항이 있다:
- **Metrics**: Service 상태, 리소스 사용량, 요청 처리량
- **Logs**: 중앙 집중식 로그 수집 및 검색
- **Visualization**: Dashboard를 통한 시각화 및 알림

Single Source of Truth로 모든 관측 데이터를 통합 관리해야 한다.

## 결정 (Decision)

Prometheus + Loki + Grafana 스택을 구성한다. Helm Chart로 배포하고, ArgoCD로 GitOps 관리한다.

구성:
- **Prometheus** (kube-prometheus-stack): Metrics 수집 및 저장
- **Loki**: Log 수집 및 저장 (Promtail Agent)
- **Grafana**: 통합 Dashboard 및 Alerting
- **ServiceMonitor**: Application 메트릭 자동 수집

## 이유 (Rationale)

| 항목 | Prometheus + Loki + Grafana | ELK Stack | Datadog/New Relic |
|------|------------------------------|-----------|-------------------|
| 비용 | 무료 (Self-hosted) | 무료 (Self-hosted) | 사용량 기반 과금 |
| Kubernetes 통합 | Native (ServiceMonitor) | 추가 설정 필요 | Agent 설치 |
| 리소스 사용량 | 보통 | 높음 (Elasticsearch) | 낮음 (SaaS) |
| 학습 곡선 | PromQL, LogQL | KQL | 낮음 |
| 운영 부담 | 보통 | 높음 | 낮음 |

Prometheus는 Kubernetes 환경에서 사실상 표준이며, ServiceMonitor CRD를 통해 메트릭 수집이 자동화된다. Loki는 Prometheus와 동일한 Label 기반 쿼리(LogQL)를 사용하여 학습 비용이 낮다.

ELK Stack은 Elasticsearch 운영 부담이 크고, SaaS 솔루션은 비용이 발생한다.

## 결과 (Consequences)

### 긍정적 측면
- Grafana에서 Metrics + Logs 통합 조회
- ServiceMonitor로 Application 메트릭 자동 수집
- Istio Envoy 메트릭과 자연스러운 통합
- PromQL/LogQL 표준 쿼리 언어 사용

### 부정적 측면 (Trade-offs)
- Prometheus 데이터 장기 보관 시 Storage 비용 증가
- Loki는 Full-text Search에 비해 제한적 (Label 기반 필터링)
- Grafana Dashboard 초기 구성 작업 필요
- Alert Rule 관리 복잡도 (PrometheusRule CRD)
