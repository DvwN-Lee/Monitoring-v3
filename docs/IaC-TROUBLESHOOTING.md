# IaC Deployment Troubleshooting Guide

K3s + ArgoCD + GitOps 기반 인프라 배포 중 발생한 문제와 해결 방법을 정리한 문서입니다.

## 목차

1. [PostgreSQL Password Race Condition](#1-postgresql-password-race-condition)
2. [Istio Gateway NodePort 불일치](#2-istio-gateway-nodeport-불일치)
3. [VirtualService Health Check Rewrite 오류](#3-virtualservice-health-check-rewrite-오류)
4. [Grafana Datasource isDefault 충돌](#4-grafana-datasource-isdefault-충돌)
5. [Istio Gateway Sidecar Injection 실패](#5-istio-gateway-sidecar-injection-실패)
6. [ExternalSecret Operator CRD/Webhook 오류](#6-externalsecret-operator-crdwebhook-오류)
7. [ArgoCD PVC Health Check 실패](#7-argocd-pvc-health-check-실패)
8. [Kustomize namePrefix Secret 참조 오류](#8-kustomize-nameprefix-secret-참조-오류)
9. [Redis Password 미설정](#9-redis-password-미설정)

---

## 1. PostgreSQL Password Race Condition

### 문제

```
psycopg2.OperationalError: FATAL: password authentication failed for user "postgres"
```

PostgreSQL Pod가 정상 Running이지만 Application Pod에서 DB 연결 실패.

### 원인

PostgreSQL `initdb`는 최초 실행 시 환경변수의 password로 계정을 생성합니다. 이후 환경변수를 변경해도 DB 내부 password는 변경되지 않습니다.

**기존 흐름 (문제):**
1. Kustomize가 `base/secret.yaml`의 placeholder(`"placeholder"`)를 `prod-app-secrets`로 배포
2. PostgreSQL Pod가 placeholder password로 `initdb` 실행
3. ExternalSecret이 GCP Secret Manager에서 실제 password를 가져와 `prod-app-secrets` 덮어씀
4. PostgreSQL 내부 password와 Secret 값 불일치 발생

### 해결

**ExternalSecret을 Single Source of Truth로 설정:**

**파일**: `k8s-manifests/overlays/gcp/kustomization.yaml`

```yaml
patches:
  # GCP overlay에서 base Secret 제외 (ExternalSecret이 prod-app-secrets를 단독 관리)
  - patch: |-
      $patch: delete
      apiVersion: v1
      kind: Secret
      metadata:
        name: app-secrets
    target:
      kind: Secret
      name: app-secrets
```

**파일**: `k8s-manifests/overlays/gcp/external-secrets/app-secrets.yaml`

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"  # 다른 리소스보다 먼저 생성
```

**파일**: `k8s-manifests/overlays/gcp/postgres/statefulset.yaml`

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # ExternalSecret 이후 생성
```

### 검증

```bash
kubectl get secret prod-app-secrets -n titanium-prod -o jsonpath="{.metadata.ownerReferences[0].kind}"
# 출력: ExternalSecret
```

**Commit**: `383f3cd`, `ff93505`

---

## 2. Istio Gateway NodePort 불일치

### 문제

```bash
curl http://34.22.103.1:31080/api/users/health
# curl: (28) Connection timed out
```

Istio Gateway를 통한 외부 요청이 timeout.

### 원인

Helm values의 NodePort 설정과 Terraform firewall 설정이 불일치.

| 구성 요소 | HTTP Port | HTTPS Port |
|---|---|---|
| Helm values (기존) | 30081 | 30444 |
| Terraform firewall | 31080 | 31443 |

Firewall이 31080/31443만 허용하므로 실제 Service port인 30081/30444로 트래픽 도달 불가.

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
          nodePort: 31080  # 30081 -> 31080
        - name: https
          port: 443
          targetPort: 443
          nodePort: 31443  # 30444 -> 31443
```

### 검증

```bash
kubectl get svc -n istio-system istio-ingressgateway
# 출력: 80:31080/TCP,443:31443/TCP

curl -s -o /dev/null -w "%{http_code}" http://34.22.103.1:31080/
# 출력: 200
```

**Commit**: `30ddbfa`

---

## 3. VirtualService Health Check Rewrite 오류

### 문제

```bash
curl http://localhost:31080/api/users/health
# {"error":"NotFound","message":"User not found","status_code":404}
```

Istio Gateway를 통한 health check 요청이 404 반환.

### 원인

VirtualService의 prefix rewrite가 URI 전체를 대체:

```yaml
- match:
  - uri:
      prefix: /api/users
  rewrite:
    uri: /users  # /api/users/health -> /users/health (X)
```

`/api/users/health`가 `/users/health`로 변환되어 user-service가 `health`를 user ID로 해석.

### 해결

**파일**: `k8s-manifests/overlays/gcp/istio/gateway.yaml`

```yaml
http:
  # Health check용 exact match를 prefix match 앞에 배치
  - match:
    - uri:
        exact: /api/users/health
    route:
    - destination:
        host: prod-user-service
        port:
          number: 8001
    rewrite:
      uri: /health  # /api/users/health -> /health
  # 기존 prefix match
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

동일한 패턴을 `/api/auth/health`에도 적용.

### 검증

```bash
curl -s http://localhost:31080/api/users/health
# {"status":"healthy"}

curl -s http://localhost:31080/api/auth/health
# {"status":"ok","service":"auth-service"}
```

**Commit**: `1a1862a`, `f2538a4`

---

## 4. Grafana Datasource isDefault 충돌

### 문제

```
Grafana 대시보드에서 Loki 로그 쿼리 실패
```

### 원인

`loki-stack` Helm values에서 Grafana datasource 설정 시 Loki와 Prometheus 모두 `isDefault: true`로 설정되어 충돌 발생.

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

Grafana UI에서 Explore > Loki datasource 선택 후 로그 쿼리 정상 동작.

**Commit**: `33aab25`

---

## 5. Istio Gateway Sidecar Injection 실패

### 문제

```bash
kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].spec.containers[0].image}'
# auto
```

Gateway Pod의 container image가 `auto`로 남아있어 실제 Envoy 이미지로 대체되지 않음.

### 원인

istiod의 MutatingWebhookConfiguration이 등록되기 전에 Gateway Pod가 생성되면 sidecar injection이 발생하지 않습니다.

### 해결

**파일**: `terraform/environments/gcp/scripts/k3s-server.sh`

```bash
# Istio Gateway sidecar injection 확인
log "Verifying Istio Gateway sidecar injection..."
for i in $(seq 1 30); do
  GW_IMAGE=$(kubectl get pod -n istio-system -l app=istio-ingressgateway \
    -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)
  if [ "$GW_IMAGE" = "auto" ] || echo "$GW_IMAGE" | grep -q "auto"; then
    log "Gateway image is 'auto' (attempt $i), restarting for injection..."
    kubectl delete pod -n istio-system -l app=istio-ingressgateway >/dev/null 2>&1
    sleep 10
  elif [ -n "$GW_IMAGE" ]; then
    log "Gateway image verified: $GW_IMAGE"
    break
  else
    sleep 5
  fi
done
```

### 검증

```bash
kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].spec.containers[0].image}'
# docker.io/istio/proxyv2:1.24.2
```

**Commit**: `733b627`, `67610cd`

---

## 6. ExternalSecret Operator CRD/Webhook 오류

### 문제

```
error: unable to recognize "externalsecret.yaml": no matches for kind "ExternalSecret" in version "external-secrets.io/v1beta1"
```

또는

```
Internal error occurred: failed calling webhook "validate.externalsecret.external-secrets.io"
```

### 원인

1. ExternalSecret CRD가 설치되지 않음
2. cert-controller가 비활성화되어 webhook TLS 인증서 미생성

### 해결

**파일**: `apps/infrastructure/external-secrets-operator.yaml`

```yaml
helm:
  values: |
    installCRDs: true
    certController:
      create: true  # webhook TLS cert 자동 생성
    webhook:
      create: true
```

**파일**: ArgoCD Application에 Sync Wave 추가

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-5"  # 다른 앱보다 먼저 배포
```

### 검증

```bash
kubectl get crd | grep external-secrets
# externalsecrets.external-secrets.io
# clustersecretstores.external-secrets.io
# secretstores.external-secrets.io

kubectl get externalsecret -n titanium-prod
# NAME              STORE                  REFRESH INTERVAL   STATUS
# prod-app-secrets  gcp-secret-store       1h                 SecretSynced
```

**Commit**: `81e25f9`, `2a1bd25`

---

## 7. ArgoCD PVC Health Check 실패

### 문제

ArgoCD에서 titanium-prod Application이 `OutOfSync` 또는 `Progressing` 상태로 유지.

### 원인

K3s의 `local-path` StorageClass는 `WaitForFirstConsumer` 모드를 사용합니다. Pod가 스케줄되기 전까지 PVC는 `Pending` 상태로 유지되며, ArgoCD 기본 health check는 이를 비정상으로 판단합니다.

### 해결

**파일**: `terraform/environments/gcp/scripts/k3s-server.sh`

```bash
# PVC health check: WaitForFirstConsumer에서 Pending 상태를 Healthy로 판단
kubectl patch configmap argocd-cm -n argocd --type=merge -p='{
  "data": {
    "resource.customizations.health.PersistentVolumeClaim": "hs = {}\nif obj.status ~= nil then\n  if obj.status.phase == \"Pending\" then\n    hs.status = \"Healthy\"\n    hs.message = \"PVC is pending (WaitForFirstConsumer)\"\n  elseif obj.status.phase == \"Bound\" then\n    hs.status = \"Healthy\"\n    hs.message = obj.status.phase\n  else\n    hs.status = \"Progressing\"\n    hs.message = obj.status.phase\n  end\nelse\n  hs.status = \"Healthy\"\nend\nreturn hs"
  }
}'
```

### 검증

```bash
kubectl get app titanium-prod -n argocd -o jsonpath="{.status.health.status}"
# Healthy
```

**Commit**: `ff93505`

---

## 8. Kustomize namePrefix Secret 참조 오류

### 문제

```
CreateContainerConfigError: secret "app-secrets" not found
```

Pod가 Secret을 찾지 못함.

### 원인

Kustomize `$patch: delete`로 base Secret을 제거하면, 해당 Secret에 대한 `namePrefix` 변환도 적용되지 않습니다. 결과적으로 Pod의 `secretKeyRef`가 `app-secrets`를 참조하지만, 실제 Secret 이름은 `prod-app-secrets`입니다.

### 해결

**파일**: `k8s-manifests/overlays/gcp/kustomization.yaml`

```yaml
patches:
  # Redis Secret 참조를 prod-app-secrets로 직접 변경
  - patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/env/0/valueFrom/secretKeyRef/name
        value: prod-app-secrets
    target:
      kind: Deployment
      name: redis-deployment
```

**파일**: `k8s-manifests/overlays/gcp/patches/user-service-deployment-patch.yaml`

```yaml
env:
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: prod-app-secrets  # namePrefix 적용 안되므로 직접 명시
        key: postgres-password
```

### 검증

```bash
kubectl get pods -n titanium-prod
# 모든 Pod Running
```

**Commit**: `ff93505`

---

## 9. Redis Password 미설정

### 문제

Redis가 인증 없이 접근 가능하여 보안 취약점 발생.

### 원인

기본 Redis 설정에 password가 설정되지 않음.

### 해결

**파일**: `k8s-manifests/base/redis-deployment.yaml`

```yaml
spec:
  containers:
  - name: redis
    env:
    - name: REDIS_PASSWORD
      valueFrom:
        secretKeyRef:
          name: app-secrets
          key: redis-password
    args:
    - "--requirepass"
    - "$(REDIS_PASSWORD)"
    livenessProbe:
      exec:
        command:
        - sh
        - -c
        - redis-cli -a "$REDIS_PASSWORD" ping | grep PONG
```

### 검증

```bash
kubectl exec -n titanium-prod deploy/prod-redis-deployment -- redis-cli ping
# NOAUTH Authentication required.

kubectl exec -n titanium-prod deploy/prod-redis-deployment -- redis-cli -a "$REDIS_PASSWORD" ping
# PONG
```

**Commit**: `7545c58`

---

## 문의 및 지원

추가 문제 발생 시 다음 정보를 포함하여 이슈를 생성해주세요:

1. **에러 메시지**: Pod logs, Events
2. **클러스터 상태**: `kubectl get pods -A`, `kubectl get app -n argocd`
3. **ArgoCD 상태**: Application sync status, health status
4. **관련 리소스**: Secret, ConfigMap, VirtualService 등
