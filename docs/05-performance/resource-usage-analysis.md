# Resource Usage Analysis

Cluster 리소스 사용량 분석 및 최적화 지점을 정리한다.

## Cluster 리소스 현황

### Node 구성

| Node | 역할 | Instance Type | vCPU | Memory |
|------|------|--------------|------|--------|
| titanium-k3s-master | Control Plane + Workload | e2-medium | 2 | 4 GB |
| titanium-k3s-worker-* (x2) | Workload | e2-standard-2 | 2 | 8 GB |
| **합계** | | | **6** | **20 GB** |

### Cluster 전체 사용량

Grafana `Kubernetes / Compute Resources / Cluster` Dashboard 기준 (Demo 시점, 2026-02-03):

| Metric | 값 | 비고 |
|--------|-----|------|
| CPU Utilisation | 10.8% | 전체 6 vCPU 대비 |
| CPU Requests Commitment | 48.5% | Request 기반 할당률 |
| Memory Utilisation | 30.3% | 전체 20 GB 대비 |
| Memory Requests Commitment | 27.9% | Request 기반 할당률 |

### Namespace별 리소스 사용량

| Namespace | CPU | Memory | Pod 수 | 용도 |
|-----------|-----|--------|--------|------|
| monitoring | 0.128 core | 1.00 GiB | 6 | Prometheus, Grafana, Loki |
| titanium-prod | 0.061 core | 600 MiB | 12 | Application (6 workload x 2 replica) |
| argocd | 0.052 core | 512 MiB | 5 | GitOps Controller |
| istio-system | 0.016 core | 136 MiB | 3 | Service Mesh Control Plane |

## 리소스 분석

### CPU 분석

- 전체 CPU 사용률 10.8%로, 현재 부하 수준에서 여유가 충분하다.
- CPU Requests Commitment 48.5%는 스케줄링 관점에서 적정 수준이다.
- Monitoring Namespace가 가장 높은 CPU를 사용하며, Prometheus scraping 및 Grafana 렌더링이 주요 원인이다.

### Memory 분석

- 전체 Memory 사용률 30.3%로 여유가 있다.
- Monitoring Stack이 전체 Memory의 약 5%를 차지한다.
- Application Namespace는 각 Service가 약 100 MiB 수준을 사용한다.

### Istio Sidecar Overhead

titanium-prod Namespace의 모든 Application Pod에 Istio sidecar(istio-proxy)가 주입되어 있다.

| 항목 | 값 |
|------|-----|
| Sidecar Pod 수 | 12 (6 workload x 2 container) |
| Sidecar당 Memory (실측) | 약 30-50 MiB |
| Sidecar Memory Request / Limit | 64Mi / 256Mi |
| Sidecar CPU Request / Limit | 50m / 200m |
| 전체 Sidecar Memory | 약 360-600 MiB |

Sidecar는 mTLS 암호화, Metrics 수집, Traffic 라우팅을 담당하므로 보안 및 관측성 대비 합리적인 비용이다.

## PromQL 모니터링 쿼리

### CPU 관련

```promql
# Node별 CPU 사용률
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Namespace별 CPU 사용량
sum(rate(container_cpu_usage_seconds_total{namespace!=""}[5m])) by (namespace)

# Pod별 CPU 사용량 Top 10
topk(10, sum(rate(container_cpu_usage_seconds_total{namespace="titanium-prod"}[5m])) by (pod))
```

### Memory 관련

```promql
# Node별 Memory 사용률
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Namespace별 Memory 사용량
sum(container_memory_working_set_bytes{namespace!=""}) by (namespace)

# Pod별 Memory 사용량 Top 10
topk(10, sum(container_memory_working_set_bytes{namespace="titanium-prod"}) by (pod))
```

### Network 관련

```promql
# Namespace별 수신 트래픽
sum(rate(container_network_receive_bytes_total{namespace!=""}[5m])) by (namespace)

# Namespace별 송신 트래픽
sum(rate(container_network_transmit_bytes_total{namespace!=""}[5m])) by (namespace)
```

## 최적화 고려사항

| 영역 | 현재 상태 | 개선 가능성 |
|------|----------|------------|
| Worker Node Spot VM | 적용됨 (`use_spot_for_workers = true`) | Worker 2대 Spot VM 운영 중 |
| HPA | 적용됨 (targetCPU 70%, min 2 / max 5) | api-gateway, auth, user, blog 4개 서비스 |
| Resource Limits | 일부 Service 미설정 | OOM 방지를 위한 Limits 설정 권장 |
| Prometheus Retention | 기본 설정 | Storage 절약을 위한 Retention 기간 조정 가능 |

## 관련 문서

- [Performance README](README.md)
- [Load Test Results](load-test-results.md)
- [Operations Guide](../03-operations/guides/operations-guide.md)
