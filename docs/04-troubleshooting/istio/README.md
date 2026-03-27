# Istio Troubleshooting

Service Mesh, Gateway, VirtualService 관련 문제.

---

## 3. VirtualService Health Check Rewrite 오류

### 문제

```bash
curl http://localhost:31080/api/users/health
# {"error":"NotFound","message":"User not found","status_code":404}
```

Istio Gateway를 통한 Health Check 요청이 404 반환.

### 원인

VirtualService의 prefix rewrite가 URI 전체를 대체:

```yaml
- match:
  - uri:
      prefix: /api/users
  rewrite:
    uri: /users
```

`/api/users/health`가 `/users/health`로 변환되어 user-service가 `health`를 user ID로 해석.

### 해결

**파일**: `k8s-manifests/overlays/gcp/istio/gateway.yaml`

Health Check용 exact match를 prefix match 앞에 배치:

```yaml
http:
  - match:
    - uri:
        exact: /api/users/health
    route:
    - destination:
        host: prod-user-service
        port:
          number: 8001
    rewrite:
      uri: /health
  - match:
    - uri:
        prefix: /api/users
    route:
    - destination:
        host: prod-user-service
        port:
          number: 8001
    rewrite:
      uri: /users
```

### 검증

```bash
$ curl -s http://localhost:31080/api/users/health
{"status":"healthy"}

$ curl -s http://localhost:31080/api/auth/health
{"status":"ok","service":"auth-service"}
```

---

## 5. Istio Gateway Sidecar Injection 실패

### 문제

```bash
kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].spec.containers[0].image}'
# auto
```

Gateway Pod의 Container Image가 `auto`로 남아있어 실제 Envoy Image로 대체되지 않음.

### 원인

istiod의 `MutatingWebhookConfiguration`이 등록되기 전에 Gateway Pod가 생성되면 Sidecar Injection이 발생하지 않는다.

### 해결

**파일**: `terraform/environments/gcp/scripts/k3s-server.sh`

Bootstrap Script에 Gateway Image 검증 및 자동 재시작 로직 추가:

```bash
for i in $(seq 1 30); do
  GW_IMAGE=$(kubectl get pod -n istio-system -l app=istio-ingressgateway \
    -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)
  if [ "$GW_IMAGE" = "auto" ] || echo "$GW_IMAGE" | grep -q "auto"; then
    kubectl delete pod -n istio-system -l app=istio-ingressgateway >/dev/null 2>&1
    sleep 10
  elif [ -n "$GW_IMAGE" ]; then
    break
  else
    sleep 5
  fi
done
```

### 검증

```bash
$ kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].spec.containers[0].image}'
docker.io/istio/proxyv2:1.24.2
```

---

## 19. Regional MIG maxSurge 오류

### 문제

```
Error: Error creating RegionInstanceGroupManager: googleapi: Error 400:
Max surge for regional managed instance group must be at least equal to the number of zones
```

### 원인

Regional MIG에서 `maxSurge` 값이 Zone 수보다 작으면 오류가 발생한다.

### 해결

**옵션 1: Zone MIG로 변경 (권장)**

```hcl
resource "google_compute_instance_group_manager" "k3s_workers" {
  name = "${var.cluster_name}-worker-mig"
  zone = var.zone
}
```

**옵션 2: maxSurge 값 조정**

```hcl
update_policy {
  max_surge_fixed = 3  # Zone 수 이상
}
```
