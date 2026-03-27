# Monitoring Troubleshooting

Prometheus, Grafana, Loki 관련 문제.

---

## 4. Grafana Datasource isDefault 충돌

### 문제

Grafana Dashboard에서 Loki 로그 쿼리 실패.

### 원인

`loki-stack` Helm values에서 Grafana Datasource 설정 시 Loki와 Prometheus 모두 `isDefault: true`로 설정되어 충돌 발생.

### 해결

**파일**: `apps/infrastructure/loki-stack.yaml`

```yaml
grafana:
  sidecar:
    datasources:
      enabled: true
      isDefaultDatasource: false  # Prometheus가 default, Loki는 false
```

### 검증

```bash
$ kubectl get configmap -n monitoring loki-stack -o jsonpath="{.data}" | grep isDefault
"isDefault": false
```
