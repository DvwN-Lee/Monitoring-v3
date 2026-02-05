# Troubleshooting Guide

K3s + ArgoCD + GitOps 기반 인프라 배포 및 테스트 중 발생한 문제와 해결 방법을 정리한 문서.

## 목차

### Part 1: IaC 배포 문제

1. [PostgreSQL Password Race Condition](#1-postgresql-password-race-condition)
2. [Istio Gateway NodePort 불일치](#2-istio-gateway-nodeport-불일치)
3. [VirtualService Health Check Rewrite 오류](#3-virtualservice-health-check-rewrite-오류)
4. [Grafana Datasource isDefault 충돌](#4-grafana-datasource-isdefault-충돌)
5. [Istio Gateway Sidecar Injection 실패](#5-istio-gateway-sidecar-injection-실패)
6. [ExternalSecret Operator CRD/Webhook 오류](#6-externalsecret-operator-crdwebhook-오류)
7. [ArgoCD PVC Health Check 실패](#7-argocd-pvc-health-check-실패)
8. [Kustomize namePrefix Secret 참조 오류](#8-kustomize-nameprefix-secret-참조-오류)
9. [Redis Password 미설정](#9-redis-password-미설정)
10. [Traffic Generator NetworkPolicy 차단](#10-traffic-generator-networkpolicy-차단)

### Part 2: Terratest 문제

11. [JSON 파싱 에러](#11-json-파싱-에러)
12. [SSH 키 경로 문제](#12-ssh-키-경로-문제)
13. [Service Account 충돌](#13-service-account-충돌)
14. [Firewall Source Ranges 테스트 실패](#14-firewall-source-ranges-테스트-실패)
15. [Network Layer 테스트 문제](#15-network-layer-테스트-문제)
16. [테스트 Timeout](#16-테스트-timeout)
17. [리소스 정리 실패](#17-리소스-정리-실패)
18. [k3s Node Password Rejection](#18-k3s-node-password-rejection)
19. [Regional MIG maxSurge 오류](#19-regional-mig-maxsurge-오류)

---

# Part 1: IaC 배포 문제

---

## 1. PostgreSQL Password Race Condition

### 문제

```
psycopg2.OperationalError: FATAL: password authentication failed for user "postgres"
```

PostgreSQL Pod가 정상 Running이지만 Application Pod에서 DB 연결 실패.

### 원인

PostgreSQL `initdb`는 최초 실행 시 환경변수의 password로 계정을 생성한다. 이후 환경변수를 변경해도 DB 내부 password는 변경되지 않는다.

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
$ kubectl get secret prod-app-secrets -n titanium-prod -o jsonpath="{.metadata.ownerReferences[0].kind}"
ExternalSecret
```

Secret의 owner가 `ExternalSecret`으로 설정되어, ExternalSecret이 Secret을 단독 관리함을 확인.

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
$ kubectl get svc -n istio-system istio-ingressgateway -o jsonpath="{.spec.ports[*].nodePort}"
31080 31443

$ curl -s -o /dev/null -w "%{http_code}" http://34.22.103.1:31080/
200
```

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

### 검증

```bash
$ curl -s http://localhost:31080/api/users/health
{"status":"healthy"}

$ curl -s http://localhost:31080/api/auth/health
{"status":"ok","service":"auth-service"}
```

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

```bash
$ kubectl get configmap -n monitoring loki-stack -o jsonpath="{.data}" | grep isDefault
"isDefault": false
```

---

## 5. Istio Gateway Sidecar Injection 실패

### 문제

```bash
kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].spec.containers[0].image}'
# auto
```

Gateway Pod의 container image가 `auto`로 남아있어 실제 Envoy 이미지로 대체되지 않음.

### 원인

istiod의 MutatingWebhookConfiguration이 등록되기 전에 Gateway Pod가 생성되면 sidecar injection이 발생하지 않는다.

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
$ kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].spec.containers[0].image}'
docker.io/istio/proxyv2:1.24.2
```

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

**ArgoCD Application에 Sync Wave 추가:**

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-5"  # 다른 앱보다 먼저 배포
```

### 검증

```bash
$ kubectl get crd | grep external-secrets
externalsecrets.external-secrets.io    2026-02-02T09:14:54Z
secretstores.external-secrets.io       2026-02-02T09:14:54Z

$ kubectl get externalsecret -n titanium-prod
NAME               STORE                      REFRESH INTERVAL   STATUS
prod-app-secrets   prod-gcpsm-secret-store    1h                 SecretSynced
```

---

## 7. ArgoCD PVC Health Check 실패

### 문제

ArgoCD에서 titanium-prod Application이 `OutOfSync` 또는 `Progressing` 상태로 유지.

### 원인

K3s의 `local-path` StorageClass는 `WaitForFirstConsumer` 모드를 사용한다. Pod가 스케줄되기 전까지 PVC는 `Pending` 상태로 유지되며, ArgoCD 기본 health check는 이를 비정상으로 판단한다.

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
$ kubectl get app titanium-prod -n argocd -o jsonpath="sync={.status.sync.status}, health={.status.health.status}"
sync=Synced, health=Healthy
```

---

## 8. Kustomize namePrefix Secret 참조 오류

### 문제

```
CreateContainerConfigError: secret "app-secrets" not found
```

Pod가 Secret을 찾지 못함.

### 원인

Kustomize `$patch: delete`로 base Secret을 제거하면, 해당 Secret에 대한 `namePrefix` 변환도 적용되지 않는다. 결과적으로 Pod의 `secretKeyRef`가 `app-secrets`를 참조하지만, 실제 Secret 이름은 `prod-app-secrets`이다.

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

### 검증

```bash
$ kubectl get pods -n titanium-prod --no-headers | grep Running | wc -l
12
```

---

## 9. Redis Password 미설정

### 문제

Redis가 인증 없이 접근 가능하여 보안 취약점 발생.

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
```

### 검증

```bash
$ kubectl exec -n titanium-prod deploy/prod-redis-deployment -- redis-cli ping
NOAUTH Authentication required.
```

---

## 10. Traffic Generator NetworkPolicy 차단

### 문제

```
=== Traffic Generator Start ===
[1/7] API Gateway health check
HTTP 503
```

Traffic Generator CronJob이 모든 서비스에서 HTTP 503 응답을 받음.

### 원인

Zero Trust NetworkPolicy 모델에서 `traffic-generator` Pod가 허용 목록에 포함되지 않음.

### 해결

**파일**: `k8s-manifests/overlays/gcp/network-policies.yaml`

각 서비스 ingress에 traffic-generator 추가:

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

---

# Part 2: Terratest 문제

---

## 11. JSON 파싱 에러

### 문제

```
Error: json: cannot unmarshal string into Go struct field .disks.diskSizeGb of type int64
Test: TestComputeAndK3s/MasterInstanceSpec
```

### 원인

gcloud 명령어에서 반환하는 `diskSizeGb` 값이 문자열이지만, Go 구조체에서 `int64`로 정의되어 JSON 파싱이 실패한다.

### 해결

**파일**: `test/30_compute_k3s_test.go`

```go
// Before
type GCPInstance struct {
    Disks []struct {
        DiskSizeGb int64 `json:"diskSizeGb"`  // int64로 정의
    } `json:"disks"`
}

// After
type GCPInstance struct {
    Disks []struct {
        DiskSizeGb string `json:"diskSizeGb"`  // string으로 변경
    } `json:"disks"`
}
```

---

## 12. SSH 키 경로 문제

### 문제 1: Tilde (~) 확장 실패

```
Error: Invalid function argument
Invalid value for "path" parameter: no file exists at "~/.ssh/id_rsa.pub"
```

### 원인

Terraform의 `file()` 함수는 tilde (`~`) 확장을 지원하지 않는다.

### 해결

**파일**: `terraform/environments/gcp/main.tf`

```hcl
# Before
metadata = {
  ssh-keys = "ubuntu:${file(var.ssh_public_key_path)}"
}

# After
metadata = {
  ssh-keys = "ubuntu:${file(pathexpand(var.ssh_public_key_path))}"
}
```

### 문제 2: 테스트에서 잘못된 SSH 키 경로 사용

### 해결

**파일**: `test/helpers.go`

```go
func GetTestTerraformVars() map[string]interface{} {
    homeDir, _ := os.UserHomeDir()
    return map[string]interface{}{
        "ssh_public_key_path": filepath.Join(homeDir, ".ssh", "titanium-key.pub"),
    }
}
```

---

## 13. Service Account 충돌

### 문제

```
Error: Error creating service account: googleapi: Error 409:
Service account terratest-k3s-sa already exists within project
```

### 원인

이전 테스트에서 생성한 Service Account가 정리되지 않고 남아있다.

### 해결

```bash
gcloud iam service-accounts delete \
  terratest-k3s-sa@PROJECT_ID.iam.gserviceaccount.com \
  --project=PROJECT_ID \
  --quiet
```

---

## 14. Firewall Source Ranges 테스트 실패

### 문제

```
--- FAIL: TestPlanFirewallSourceRanges (2.34s)
    Expected SSH firewall to have only IAP range (35.235.240.0/20)
    but found: [35.235.240.0/20, 14.35.115.201/32]
```

### 원인

`test-ssh.auto.tfvars` 파일이 이전 테스트에서 생성되어 남아있다.

### 해결

```bash
rm -f terraform/environments/gcp/test-ssh.auto.tfvars
```

---

## 15. Network Layer 테스트 문제

### 문제: VPC 이미 존재

```
Error: Error creating network: googleapi: Error 409:
The resource 'projects/.../global/networks/terratest-k3s-vpc' already exists
```

### 해결

```bash
gcloud compute networks delete terratest-k3s-vpc \
  --project=PROJECT_ID \
  --quiet
```

---

## 16. 테스트 Timeout

### 문제

```
panic: test timed out after 30m0s
```

### 해결

```bash
# Timeout 값 증가
go test -v -run "TestFullIntegration" -timeout 45m
```

---

## 17. 리소스 정리 실패

### 문제

테스트 실패 후 GCP 리소스가 남아있음.

### 확인

```bash
gcloud compute instances list --filter="name~^tt-" --project=PROJECT_ID
gcloud compute networks list --filter="name~^tt-" --project=PROJECT_ID
```

### 정리

```bash
# Terraform으로 정리
terraform destroy -auto-approve

# 또는 gcloud로 직접 삭제
gcloud compute instances delete INSTANCE_NAME --zone=ZONE --quiet
```

---

## 18. k3s Node Password Rejection

### 문제

```
E0101 12:34:56.123456 12345 main.go:48] Node password rejected, duplicate hostname
```

### 원인

MIG Auto-healing으로 Worker VM이 재생성될 때, 동일한 hostname으로 k3s에 Join을 시도하면 password 불일치로 거부된다.

### 해결

**파일**: `terraform/environments/gcp/scripts/k3s-agent.sh`

```bash
# --with-node-id 플래그 추가
curl -sfL https://get.k3s.io | K3S_URL="https://${master_ip}:6443" K3S_TOKEN="${k3s_token}" sh -s - --with-node-id
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
  zone = var.zone  # 단일 Zone 지정
}
```

**옵션 2: maxSurge 값 조정**

```hcl
update_policy {
  max_surge_fixed = 3  # Zone 수 이상
}
```

---

## 일반 디버깅 팁

### 로그 확인

```bash
# Terraform 로그
export TF_LOG=DEBUG
terraform apply

# Pod 로그
kubectl logs -n NAMESPACE POD_NAME -f
```

### 특정 테스트만 실행

```bash
go test -v -run "TestComputeAndK3s/MasterInstanceSpec" -timeout 10m
```

### GCP Console 링크

- [Compute Engine](https://console.cloud.google.com/compute/instances)
- [VPC Networks](https://console.cloud.google.com/networking/networks/list)
- [Firewall Rules](https://console.cloud.google.com/networking/firewalls/list)

---

## 문의 및 지원

추가 문제 발생 시 다음 정보를 포함하여 이슈를 생성:

1. **에러 메시지**: 전체 스택 트레이스
2. **클러스터 상태**: `kubectl get pods -A`, `kubectl get app -n argocd`
3. **환경 정보**: `go version`, `terraform version`, `gcloud version`
