# Browser Testing 결과 - Monitoring Dashboard 검증

## 테스트 개요

- **테스트 일시**: 2026-01-27
- **환경**: minikube (local)
- **목적**: 모니터링 대시보드 및 Metrics 수집 상태 검증

---

## 환경 정보

| 항목 | 값 |
|------|-----|
| Minikube IP | 192.168.49.2 |
| Minikube 상태 | Running |
| Kubernetes API | 정상 |

---

## 테스트 결과 요약

| 항목 | 상태 | 비고 |
|------|------|------|
| Prometheus Targets 수집 | 성공 | 27개 targets, titanium-prod Pod 모두 UP |
| Loki 로그 수집 | 성공 | titanium-prod namespace 로그 정상 수집 |
| Kiali Service | 성공 | 정상 실행 중, token 인증 활성화 |
| Grafana 접근 | 실패 | Init 컨테이너 권한 문제 (CrashLoopBackOff) |

---

## 1. Prometheus Targets 검증

### 실행 방법
```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
curl -s http://localhost:9090/api/v1/targets
```

### 결과

**Active Targets**: 27개

**titanium-prod namespace Envoy Metrics** (PodMonitor 기반):
- prod-api-gateway-deployment-7c98bc99bc-46gbp: UP
- prod-api-gateway-deployment-7c98bc99bc-g88ct: UP
- prod-user-service-deployment-7f96568f75-czm8w: UP
- prod-user-service-deployment-7f96568f75-wk4ts: UP
- prod-blog-service-deployment-548c7b456d-cm6jn: UP
- prod-blog-service-deployment-548c7b456d-pzns5: UP
- prod-auth-service-deployment-8b76fbf77-9cd7c: UP
- prod-auth-service-deployment-8b76fbf77-dc2l9: UP
- prod-redis-deployment-5fdb4bd756-6qldb: UP
- postgresql-c796669fd-t8fs8: UP

**Kubernetes 시스템 Metrics**:
- apiserver: UP
- coredns: UP (2개 Pod)
- kubelet: UP
- kube-proxy: UP
- node-exporter: UP
- kube-state-metrics: UP
- prometheus-operator: UP

### 주요 사항

1. **Application ServiceMonitor 비활성화됨**:
   - kustomization.yaml에서 `application-servicemonitors.yaml` 주석 처리
   - 이유: Istio mTLS STRICT 모드로 인해 Prometheus가 메시 외부에서 스크래핑 불가
   - 대안: PodMonitor를 통해 Envoy proxy metrics 수집 (포트 15090)

2. **Envoy Metrics 수집 정상**:
   - PodMonitor `prod-envoy-stats-monitor`가 titanium-prod namespace의 모든 istio-proxy 컨테이너에서 metrics 수집
   - Istio 서비스 메시 트래픽 metrics 확보

3. **Prometheus Pod 재시작 후 정상 작동**:
   - 초기에 active targets가 0개였으나 Pod 재시작 후 27개로 정상화
   - Prometheus Operator가 ServiceMonitor/PodMonitor 설정을 올바르게 반영

---

## 2. Loki 로그 수집 검증

### 실행 방법
```bash
kubectl port-forward -n monitoring svc/loki-stack 3100:3100
curl -s -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="titanium-prod"}' \
  --data-urlencode 'limit=5'
```

### 결과

**로그 수집 상태**: 정상

**수집된 로그 스트림**: 4개

**샘플 로그**:
```json
{
  "stream": {
    "job": "titanium-prod/titanium",
    "namespace": "titanium-prod",
    "node_name": "minikube",
    "pod": "prod-auth-service-deployment-8b76fbf77-9cd7c",
    "app": "titanium",
    "container": "auth-service-container",
    "filename": "/var/log/pods/titanium-prod_prod-auth-service-deployment-8b76fbf77-9cd7c_fd1b04f8-09cf-43a0-8f44-3bb345ef4724/auth-service-container/0.log"
  },
  "log": "INFO:     127.0.0.6:44881 - \"GET /health HTTP/1.1\" 200 OK\n"
}
```

### 주요 사항

1. **Loki와 Promtail 정상 작동**:
   - Loki Pod: Running
   - Promtail DaemonSet: Running

2. **titanium-prod namespace 로그 수집 확인**:
   - Pod 로그가 Loki에 정상적으로 저장됨
   - Label을 통한 필터링 가능 (namespace, pod, container 등)

---

## 3. Kiali Service Graph 검증

### 실행 방법
```bash
kubectl port-forward -n istio-system svc/kiali 20001:20001
```

### 결과

**Kiali 상태**: 정상 실행 중

**인증 모드**: token (ServiceAccount token 필요)

**설정 정보**:
- Version: v2.4.0
- Web Root: /kiali
- Prometheus 연결: http://prometheus-kube-prometheus-prometheus.monitoring:9090
- Grafana 연결: http://prometheus-grafana.monitoring:80

**로그 메시지**:
```
2026-01-27T01:51:17Z INF [Kiali Cache] Started
```

### 주요 사항

1. **Kiali 정상 실행**:
   - Pod 상태: Running (1/1 Ready)
   - 캐시 초기화 완료

2. **인증 필요**:
   - token 기반 인증 활성화
   - API 접근 시 ServiceAccount token 필요
   - 브라우저 접근 시 로그인 필요

3. **외부 서비스 연결 설정**:
   - Prometheus와 Grafana 연결 설정됨
   - Istio root namespace: istio-system

---

## 4. Grafana 접근 시도

### 문제 상황

**Grafana Pod 상태**: CrashLoopBackOff

**Pod 목록**:
```
prometheus-grafana-59d5bc97cc-qzd64    0/3     Init:CrashLoopBackOff
prometheus-grafana-866878b4f-8p9fs     0/3     Init:CrashLoopBackOff
```

**Init 컨테이너 에러 로그**:
```
chown: /var/lib/grafana/pdf: Permission denied
chown: /var/lib/grafana/csv: Permission denied
chown: /var/lib/grafana/png: Permission denied
```

### 근본 원인

1. **PVC 권한 문제**:
   - PersistentVolumeClaim의 기존 데이터에 대한 권한 문제
   - Init 컨테이너 (chown-data)가 /var/lib/grafana 디렉토리 권한 변경 실패

2. **minikube hostPath 볼륨 제약**:
   - minikube 환경에서 hostPath 기반 PVC의 권한 설정 제한
   - fsGroup 설정이 제대로 작동하지 않음

### 해결 방안

**단기 해결책**:
1. PVC 삭제 및 재생성:
```bash
kubectl delete pvc prometheus-grafana -n monitoring
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana
```

2. Grafana Deployment의 securityContext 조정:
   - initContainer의 securityContext 수정
   - runAsUser: 0 추가 고려

**장기 해결책**:
1. GCP 환경에서는 GCE PersistentDisk 사용으로 문제 해소 예상
2. Grafana Helm Chart values에서 initChownData 비활성화 검토

### Grafana Datasource 설정 수정

**문제**:
- Loki와 Prometheus datasource 모두 `isDefault: true`로 설정되어 Grafana 시작 실패
- 에러: "Only one datasource per organization can be marked as default"

**조치**:
```bash
# Loki datasource ConfigMap 수정
kubectl patch configmap loki-stack -n monitoring --type='json' \
  -p='[{"op": "replace", "path": "/data/loki-stack-datasource.yaml", "value": "apiVersion: 1\ndatasources:\n- name: Loki\n  type: loki\n  access: proxy\n  url: \"http://loki-stack:3100\"\n  version: 1\n  isDefault: false\n  jsonData:\n    {}"}]'
```

**결과**: 설정 수정 완료, 그러나 Init 컨테이너 권한 문제로 Grafana 여전히 실행 불가

---

## 결론

### 성공한 항목

1. **Prometheus Targets 수집**: 27개 targets 정상 수집, titanium-prod Pod Envoy metrics 모두 UP
2. **Loki 로그 수집**: titanium-prod namespace 로그 정상 수집 및 쿼리 가능
3. **Kiali Service**: 정상 실행, Istio 서비스 메시 모니터링 준비 완료

### 미해결 항목

1. **Grafana 접근**: Init 컨테이너 권한 문제로 실행 실패
   - minikube 환경 특유의 PVC 권한 문제
   - GCP 환경에서는 정상 작동할 것으로 예상

### 권장 사항

1. **Grafana 문제 해결**:
   - GCP 환경에서 재배포 시 GCE PersistentDisk 사용으로 해결 가능
   - minikube에서 임시 해결을 위해 initChownData 비활성화 고려

2. **Application Metrics 수집**:
   - 현재 Envoy proxy metrics로 충분
   - 향후 Application custom metrics 필요 시 mTLS 설정과 함께 ServiceMonitor 활성화

3. **Kiali 활용**:
   - ServiceAccount token 획득하여 Kiali UI 접근
   - titanium-prod namespace의 서비스 그래프 시각화 확인

---

## 테스트 명령 요약

```bash
# Prometheus 접근
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length'

# Loki 접근
kubectl port-forward -n monitoring svc/loki-stack 3100:3100
curl -s -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="titanium-prod"}' \
  --data-urlencode 'limit=5'

# Kiali 접근
kubectl port-forward -n istio-system svc/kiali 20001:20001
# 브라우저: http://localhost:20001/kiali

# Grafana 상태 확인
kubectl get pods -n monitoring | grep grafana
kubectl logs -n monitoring <grafana-pod-name> -c init-chown-data
```
