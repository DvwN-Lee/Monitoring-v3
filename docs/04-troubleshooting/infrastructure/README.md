# Infrastructure Troubleshooting

VM, Network, Firewall 등 GCP Infrastructure 관련 문제.

---

## 2. Istio Gateway NodePort 불일치

### 문제

```bash
curl http://34.22.103.1:31080/api/users/health
# curl: (28) Connection timed out
```

Istio Gateway를 통한 외부 요청이 timeout.

### 원인

Helm values의 NodePort 설정과 Terraform Firewall 설정이 불일치.

| 구성 요소 | HTTP Port | HTTPS Port |
|---|---|---|
| Helm values (기존) | 30081 | 30444 |
| Terraform Firewall | 31080 | 31443 |

Firewall이 31080/31443만 허용하므로 실제 Service Port인 30081/30444로 트래픽 도달 불가.

### 해결

**파일**: `apps/infrastructure/istio-ingressgateway.yaml`

```yaml
helm:
  values: |
    service:
      type: NodePort
      ports:
        - name: http2
          port: 80
          targetPort: 80
          nodePort: 31080
        - name: https
          port: 443
          targetPort: 443
          nodePort: 31443
```

### 검증

```bash
$ kubectl get svc -n istio-system istio-ingressgateway -o jsonpath="{.spec.ports[*].nodePort}"
31080 31443

$ curl -s -o /dev/null -w "%{http_code}" http://34.22.103.1:31080/
200
```

---

## 7. ArgoCD PVC Health Check 실패

### 문제

ArgoCD에서 titanium-prod Application이 `OutOfSync` 또는 `Progressing` 상태로 유지.

### 원인

K3s의 `local-path` StorageClass는 `WaitForFirstConsumer` 모드를 사용한다. Pod가 스케줄되기 전까지 PVC는 `Pending` 상태로 유지되며, ArgoCD 기본 Health Check는 이를 비정상으로 판단한다.

### 해결

**파일**: `terraform/environments/gcp/scripts/k3s-server.sh`

ArgoCD ConfigMap에 Custom Health Check Lua Script를 추가하여, `Pending` 상태의 PVC를 `Healthy`로 판단하도록 변경.

```bash
kubectl patch configmap argocd-cm -n argocd --type=merge -p='{
  "data": {
    "resource.customizations.health.PersistentVolumeClaim": "hs = {}\nif obj.status ~= nil then\n  if obj.status.phase == \"Pending\" then\n    hs.status = \"Healthy\"\n    hs.message = \"PVC is pending (WaitForFirstConsumer)\"\n  elseif obj.status.phase == \"Bound\" then\n    hs.status = \"Healthy\"\n    hs.message = obj.status.phase\n  else\n    hs.status = \"Progressing\"\n    hs.message = obj.status.phase\n  end\nelse\n  hs.status = \"Healthy\"\nend\nreturn hs"
  }
}'
```

### 검증

```bash
$ kubectl get app titanium-prod -n argocd -o jsonpath="sync={.status.sync.status}, health={.status.health.status}"
sync=Synced, health=Healthy
```

---

## 10. Traffic Generator NetworkPolicy 차단

### 문제

```
=== Traffic Generator Start ===
[1/7] API Gateway health check
HTTP 503
```

Traffic Generator CronJob이 모든 서비스에서 HTTP 503 응답.

### 원인

Zero Trust NetworkPolicy 모델에서 `traffic-generator` Pod가 허용 목록에 포함되지 않음.

### 해결

**파일**: `k8s-manifests/overlays/gcp/network-policies.yaml`

각 서비스 Ingress에 traffic-generator 추가:

```yaml
- from:
    - podSelector:
        matchLabels:
          app: traffic-generator
  ports:
    - protocol: TCP
      port: 8000
```

### 검증

```bash
$ kubectl logs -n titanium-prod -l app=traffic-generator --tail=10
[1/7] API Gateway health check
HTTP 200
[5/7] Blog posts list
HTTP 200
=== Traffic Generator Complete ===
```
