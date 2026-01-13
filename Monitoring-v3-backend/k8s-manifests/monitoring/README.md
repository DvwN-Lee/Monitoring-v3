# Monitoring Stack Configuration

이 디렉터리는 Kubernetes Cluster에 배포되는 모니터링 스택(Prometheus, Grafana, Loki)의 설정 파일들을 포함합니다.

## 개요

본 프로젝트는 **Prometheus + Grafana + Loki**로 구성된 관측성(Observability) 스택을 통해 Microservice의 메트릭, 로그, 트레이스를 통합 수집하고 시각화합니다.

## 구성 요소

### 1. Prometheus (메트릭 수집)

![Prometheus](https://raw.githubusercontent.com/DvwN-Lee/Monitoring-v2/main/docs/04-operations/screenshots/prometheus.png)

**역할**: 애플리케이션 및 인프라 메트릭을 수집하고 저장하는 시계열 데이터베이스

**설정 파일**:
- `prometheus-values.yaml`: Prometheus 서버 설정
- `prometheus-rules.yaml`: 알림 규칙 정의
- `servicemonitor-*.yaml`: 각 Microservice의 메트릭 수집 대상 정의

**주요 설정**:
```yaml
# prometheus-values.yaml
prometheus:
  prometheusSpec:
    retention: 15d  # 메트릭 보관 기간
    resources:
      requests:
        memory: 512Mi
        cpu: 200m
```

**ServiceMonitor**:
각 Microservice는 ServiceMonitor를 통해 Prometheus의 수집 대상으로 등록됩니다:
- `servicemonitor-api-gateway.yaml`: API Gateway 메트릭 수집
- `servicemonitor-auth-service.yaml`: Auth Service 메트릭 수집
- `servicemonitor-user-service.yaml`: User Service 메트릭 수집
- `servicemonitor-blog-service.yaml`: Blog Service 메트릭 수집

### 2. Grafana (시각화 대시보드)

![Grafana Golden Signals](https://raw.githubusercontent.com/DvwN-Lee/Monitoring-v2/main/docs/04-operations/screenshots/grafana-golden-signals-full.png)

**역할**: Prometheus와 Loki에서 수집한 데이터를 시각화하는 대시보드 플랫폼

**설정 파일**:
- `dashboard-configmap.yaml`: Grafana 대시보드 정의
- `loki-datasource.yaml`: Loki 데이터소스 연결 설정

**주요 대시보드**:
- **Golden Signals Dashboard**:
  - Latency (지연시간): P95, P99 응답 시간
  - Traffic (트래픽): 초당 요청 수 (RPS)
  - Errors (에러율): HTTP 4xx, 5xx 에러 비율
  - Saturation (포화도): CPU, 메모리 사용률

**접속 정보**:
- URL: `http://10.0.11.168:30300`
- 기본 계정: `admin` / `prom-operator`

### 3. Loki (중앙 로깅)

![Loki Logs](https://raw.githubusercontent.com/DvwN-Lee/Monitoring-v2/main/docs/04-operations/screenshots/loki-logs.png)

**역할**: Container 로그를 수집하고 저장하는 로그 집계 시스템

**설정 파일**:
- `loki-stack-values.yaml`: Loki 서버 및 Promtail 에이전트 설정
- `loki-v3-values.yaml`: Loki v3 업그레이드용 설정
- `promtail-values.yaml`: Promtail DaemonSet 설정

**주요 설정**:
```yaml
# loki-stack-values.yaml
loki:
  persistence:
    enabled: true
    size: 10Gi
  config:
    limits_config:
      retention_period: 168h  # 7일
```

**Promtail**:
- 각 Kubernetes Node에서 DaemonSet으로 실행
- `/var/log/pods`에서 Container 로그 수집
- Loki 서버로 전송

## 배포 방법

### Helm을 통한 배포

```bash
# Namespace 생성
kubectl apply -f namespace.yaml

# Prometheus + Grafana 배포
helm install prometheus prometheus-community/kube-prometheus-stack \
  -f prometheus-values.yaml \
  -n monitoring

# Loki Stack 배포
helm install loki grafana/loki-stack \
  -f loki-stack-values.yaml \
  -n monitoring

# ServiceMonitor 적용
kubectl apply -f servicemonitor-*.yaml
```

### 배포 검증

```bash
# Pod 상태 확인
kubectl get pods -n monitoring

# Prometheus Targets 확인
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring
# 브라우저에서 http://localhost:9090/targets 접속

# Grafana 접속 확인
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
# 브라우저에서 http://localhost:3000 접속
```

## 설정 파일 설명

### ServiceMonitor

ServiceMonitor는 Prometheus Operator가 메트릭 수집 대상을 자동으로 인식하도록 하는 커스텀 리소스입니다.

```yaml
# servicemonitor-api-gateway.yaml 예시
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api-gateway
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: api-gateway
  endpoints:
  - port: http
    interval: 30s
    path: /metrics
```

### Prometheus Rules

알림 규칙을 정의하여 특정 조건이 만족되면 AlertManager를 통해 알림을 전송합니다.

```yaml
# prometheus-rules.yaml 예시
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: application-alerts
spec:
  groups:
  - name: api-gateway
    rules:
    - alert: HighErrorRate
      expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.05
      for: 5m
      annotations:
        summary: "High error rate detected"
```

## 모니터링 메트릭

### 수집되는 주요 메트릭

**애플리케이션 메트릭**:
- `http_requests_total`: 총 HTTP 요청 수
- `http_request_duration_seconds`: HTTP 요청 처리 시간
- `http_requests_in_flight`: 현재 처리 중인 요청 수

**인프라 메트릭**:
- `container_cpu_usage_seconds_total`: Container CPU 사용량
- `container_memory_usage_bytes`: Container 메모리 사용량
- `kube_pod_status_phase`: Pod 상태

**Istio 메트릭**:
- `istio_requests_total`: Istio Service Mesh 요청 수
- `istio_request_duration_milliseconds`: 요청 지연시간
- `istio_tcp_connections_opened_total`: TCP 연결 수

## LogQL 쿼리 예시

Loki에서 로그를 조회하기 위한 LogQL 쿼리 예시입니다.

```logql
# titanium-prod Namespace의 모든 로그
{namespace="titanium-prod"}

# 특정 Service의 로그
{namespace="titanium-prod", app="api-gateway"}

# 에러 로그만 필터링
{namespace="titanium-prod"} |= "error"

# 최근 5분간 로그 볼륨
sum(count_over_time({namespace="titanium-prod"}[5m]))
```

## 트러블슈팅

### Prometheus 메트릭 수집 실패

1. ServiceMonitor의 레이블이 Service와 일치하는지 확인
2. Prometheus Targets 페이지에서 상태 확인
3. 애플리케이션의 `/metrics` 엔드포인트 접근 가능 여부 확인

### Grafana 대시보드 데이터 없음

1. Grafana 데이터소스 연결 테스트 (Configuration > Data Sources)
2. Prometheus 쿼리가 올바른지 확인
3. 시간 범위(Time Range) 설정 확인

### Loki 로그 수집 안 됨

1. Promtail Pod 로그 확인: `kubectl logs -n monitoring -l app=promtail`
2. Loki 데이터소스 연결 확인
3. LogQL 쿼리 문법 확인

## 참고 문서

- [Prometheus Operator Documentation](https://prometheus-operator.dev/)
- [Grafana Documentation](https://grafana.com/docs/)
- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [프로젝트 아키텍처 문서](../../docs/02-architecture/architecture.md)
- [트러블슈팅 가이드](../../docs/04-troubleshooting/monitoring/)

---

**작성일**: 2025년 11월 14일
**버전**: 1.0
