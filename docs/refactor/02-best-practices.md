# Best Practices

이 문서는 인프라 코드의 품질과 운영 안정성 향상을 위한 Best Practice 개선 항목을 기술한다.

---

## 목차

1. [BP-001: Terraform 변수 Validation 부재](#bp-001-terraform-변수-validation-부재)
2. [BP-002: Staging 환경 미구현](#bp-002-staging-환경-미구현)
3. [BP-003: Deployment 중복 (DRY 위반)](#bp-003-deployment-중복-dry-위반)
4. [BP-004: External Secrets 미사용](#bp-004-external-secrets-미사용)
5. [BP-005: startupProbe 미설정](#bp-005-startupprobe-미설정)

---

## BP-001: Terraform 변수 Validation 부재

### 문제

**파일**: `terraform/modules/instance/variables.tf`

```hcl
# Before (문제 코드)
variable "cluster_name" {
  description = "Name of the k3s cluster"
  type        = string
}

variable "zone" {
  description = "CloudStack zone name"
  type        = string
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
}
```

변수에 validation block이 없어 잘못된 값이 입력되어도 Terraform plan 단계에서 감지되지 않는다.

### 원인

초기 개발 시 변수 검증 로직을 추가하지 않았다.

### 해결 방법

```hcl
# After (수정 코드)
variable "cluster_name" {
  description = "Name of the k3s cluster"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.cluster_name))
    error_message = "Cluster name must be 3-21 characters, start with lowercase letter, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "zone" {
  description = "GCP zone name"
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]-[a-z]$", var.zone))
    error_message = "Zone must be a valid GCP zone format (e.g., asia-northeast3-a)."
  }
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 10
    error_message = "Worker count must be between 1 and 10."
  }
}

variable "master_machine_type" {
  description = "Machine type for master node"
  type        = string
  default     = "e2-medium"

  validation {
    condition     = contains(["e2-micro", "e2-small", "e2-medium", "e2-standard-2", "e2-standard-4"], var.master_machine_type)
    error_message = "Master machine type must be one of: e2-micro, e2-small, e2-medium, e2-standard-2, e2-standard-4."
  }
}

variable "subnet_cidr" {
  description = "CIDR block for subnet"
  type        = string
  default     = "10.128.0.0/20"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "Subnet CIDR must be a valid IPv4 CIDR notation."
  }
}
```

### 검증

```bash
# 잘못된 값으로 테스트
terraform plan -var="cluster_name=123invalid"

# 예상 결과:
# Error: Invalid value for variable
# Cluster name must be 3-21 characters, start with lowercase letter...

terraform plan -var="worker_count=100"
# Error: Worker count must be between 1 and 10.
```

---

## BP-002: Staging 환경 미구현

### 문제

현재 환경 구성:
```
terraform/environments/
└── gcp/          # Production 환경만 존재

k8s-manifests/overlays/
├── local/        # 로컬 개발 환경
└── gcp/          # Production 환경
```

Staging 환경이 없어 Production 배포 전 통합 테스트가 불가능하다.

### 원인

프로젝트 초기 단계에서 환경 분리를 간소화했다.

### 해결 방법

**Step 1: Terraform Staging 환경 생성**

```
terraform/environments/
├── gcp/              # Production
└── staging/          # Staging (신규)
    ├── main.tf
    ├── variables.tf
    ├── backend.tf
    └── terraform.tfvars
```

```hcl
# terraform/environments/staging/main.tf
module "k3s_cluster" {
  source = "../../modules/k3s-gcp"  # 공용 모듈 사용

  project_id          = var.project_id
  region              = var.region
  zone                = var.zone
  cluster_name        = "titanium-staging"
  master_machine_type = "e2-small"      # Production보다 작은 사양
  worker_machine_type = "e2-medium"
  worker_count        = 1               # 최소 Worker
  use_spot_for_workers = true
}
```

```hcl
# terraform/environments/staging/backend.tf
terraform {
  backend "gcs" {
    bucket = "titanium-terraform-state"
    prefix = "staging/k3s-cluster"
  }
}
```

**Step 2: Kubernetes Staging Overlay 생성**

```
k8s-manifests/overlays/
├── local/
├── staging/          # Staging (신규)
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   └── configmap-patch.yaml
└── gcp/
```

```yaml
# k8s-manifests/overlays/staging/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: titanium-staging
namePrefix: stg-

resources:
  - ../../base
  - namespace.yaml

configMapGenerator:
  - name: app-config
    behavior: merge
    literals:
      - ENVIRONMENT=staging
      - LOG_LEVEL=DEBUG
      - POSTGRES_HOST=stg-postgresql-service

replicas:
  - name: user-service-deployment
    count: 1
  - name: blog-service-deployment
    count: 1
  - name: auth-service-deployment
    count: 1
  - name: api-gateway-deployment
    count: 1

labels:
  - pairs:
      environment: staging
```

**Step 3: ArgoCD Application 추가**

```yaml
# terraform/modules/argocd-apps/staging-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: titanium-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/DvwN-Lee/Monitoring-v3.git
    targetRevision: develop
    path: k8s-manifests/overlays/staging
  destination:
    server: https://kubernetes.default.svc
    namespace: titanium-staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Step 4: CI/CD Pipeline 수정**

```yaml
# .github/workflows/cd.yml 수정
jobs:
  deploy-staging:
    if: github.ref == 'refs/heads/develop'
    # staging 환경 배포

  deploy-production:
    if: github.ref == 'refs/heads/main'
    needs: deploy-staging  # staging 배포 후 production 배포
```

### 검증

```bash
# Staging 환경 배포
cd terraform/environments/staging
terraform apply

# Staging 클러스터 확인
KUBECONFIG=~/.kube/config-staging kubectl get nodes
KUBECONFIG=~/.kube/config-staging kubectl get pods -n titanium-staging
```

---

## BP-003: Deployment 중복 (DRY 위반)

### 문제

**파일 비교**:
- `k8s-manifests/base/api-gateway-deployment.yaml`
- `k8s-manifests/base/user-service-deployment.yaml`
- `k8s-manifests/base/auth-service-deployment.yaml`
- `k8s-manifests/base/blog-service-deployment.yaml`

```yaml
# 4개 파일 모두 동일한 패턴 반복
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "200m"
livenessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 5
  periodSeconds: 5
```

동일한 설정이 4개 파일에 중복되어 유지보수가 어렵다.

### 원인

Kustomize의 고급 기능(Components)을 활용하지 않았다.

### 해결 방법

**Option 1: Kustomize Components 활용**

```yaml
# k8s-manifests/components/standard-probes/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component

patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: not-used
      spec:
        template:
          spec:
            containers:
            - name: not-used
              resources:
                requests:
                  memory: "128Mi"
                  cpu: "100m"
                limits:
                  memory: "256Mi"
                  cpu: "200m"
              livenessProbe:
                httpGet:
                  path: /health
                  port: http
                initialDelaySeconds: 30
                periodSeconds: 10
              readinessProbe:
                httpGet:
                  path: /health
                  port: http
                initialDelaySeconds: 5
                periodSeconds: 5
    target:
      kind: Deployment
```

```yaml
# k8s-manifests/overlays/gcp/kustomization.yaml 수정
components:
  - ../../components/standard-probes
```

**Option 2: Helm Chart 전환 (장기)**

```
charts/titanium-service/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── deployment.yaml
    └── service.yaml
```

```yaml
# charts/titanium-service/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.name }}-deployment
spec:
  replicas: {{ .Values.replicas }}
  template:
    spec:
      containers:
      - name: {{ .Values.name }}-container
        image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
        ports:
        - containerPort: {{ .Values.port }}
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
        livenessProbe:
          {{- toYaml .Values.probes.liveness | nindent 10 }}
        readinessProbe:
          {{- toYaml .Values.probes.readiness | nindent 10 }}
```

### 검증

```bash
# Kustomize 렌더링 확인
kustomize build k8s-manifests/overlays/gcp | grep -A20 "livenessProbe"

# 모든 Deployment에 동일한 설정 적용 확인
kubectl get deployments -n titanium-prod -o yaml | grep -A5 "resources:"
```

---

## BP-004: External Secrets 미사용

### 문제

**파일**: `k8s-manifests/base/secret.yaml`

```yaml
# Before (문제 코드)
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
type: Opaque
data:
  POSTGRES_PASSWORD: VGVtcFBhc3N3b3JkMTIzIQ==  # Base64 encoded
  JWT_SECRET_KEY: and0LXNpZ25pbmcta2V5          # Git에 저장됨
```

Secret이 Base64 인코딩된 상태로 Git에 저장되어 보안 위험이 있다.

### 원인

External Secrets Operator를 도입하지 않았다.

### 해결 방법

**Step 1: External Secrets Operator 설치**

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

**Step 2: GCP Secret Manager에 Secret 저장**

```bash
# Secret 생성
echo -n "RealSecurePassword123!" | gcloud secrets create postgres-password \
  --data-file=- --replication-policy="automatic"

echo -n "jwt-secure-signing-key-prod" | gcloud secrets create jwt-secret-key \
  --data-file=- --replication-policy="automatic"
```

**Step 3: SecretStore 생성**

```yaml
# k8s-manifests/overlays/gcp/external-secrets/secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: gcp-secret-store
  namespace: titanium-prod
spec:
  provider:
    gcpsm:
      projectID: ${GCP_PROJECT_ID}
      auth:
        workloadIdentity:
          clusterLocation: asia-northeast3
          clusterName: titanium-k3s
          serviceAccountRef:
            name: external-secrets-sa
```

**Step 4: ExternalSecret 생성**

```yaml
# k8s-manifests/overlays/gcp/external-secrets/app-secrets.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secrets
  namespace: titanium-prod
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcp-secret-store
    kind: SecretStore
  target:
    name: app-secrets
    creationPolicy: Owner
  data:
  - secretKey: POSTGRES_PASSWORD
    remoteRef:
      key: postgres-password
  - secretKey: JWT_SECRET_KEY
    remoteRef:
      key: jwt-secret-key
  - secretKey: INTERNAL_API_SECRET
    remoteRef:
      key: internal-api-secret
  - secretKey: REDIS_PASSWORD
    remoteRef:
      key: redis-password
```

**Step 5: 기존 Secret 파일 제거**

```yaml
# k8s-manifests/base/secret.yaml 삭제 또는 주석 처리
# Secret은 External Secrets Operator가 자동 생성
```

### 검증

```bash
# ExternalSecret 상태 확인
kubectl get externalsecret -n titanium-prod

# 생성된 Secret 확인
kubectl get secret app-secrets -n titanium-prod -o yaml

# Secret 동기화 상태 확인
kubectl describe externalsecret app-secrets -n titanium-prod
```

---

## BP-005: startupProbe 미설정

### 문제

**파일**: `k8s-manifests/base/api-gateway-deployment.yaml:40-49`

```yaml
# Before (문제 코드)
livenessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 5
  periodSeconds: 5
```

startupProbe가 없어 애플리케이션 시작 시간이 긴 경우 livenessProbe 실패로 Pod가 재시작될 수 있다.

### 원인

Kubernetes 1.18 이후 도입된 startupProbe를 적용하지 않았다.

### 해결 방법

```yaml
# After (수정 코드)
startupProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 0
  periodSeconds: 5
  failureThreshold: 30  # 최대 150초 대기 (5초 * 30회)
livenessProbe:
  httpGet:
    path: /health
    port: http
  periodSeconds: 10
  failureThreshold: 3
  # initialDelaySeconds 제거 - startupProbe가 대신 처리
readinessProbe:
  httpGet:
    path: /health
    port: http
  periodSeconds: 5
  failureThreshold: 3
```

**Kustomize Patch로 일괄 적용**

```yaml
# k8s-manifests/overlays/gcp/patches/startup-probe-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: not-used
spec:
  template:
    spec:
      containers:
      - name: not-used
        startupProbe:
          httpGet:
            path: /health
            port: http
          initialDelaySeconds: 0
          periodSeconds: 5
          failureThreshold: 30
        livenessProbe:
          httpGet:
            path: /health
            port: http
          periodSeconds: 10
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health
            port: http
          periodSeconds: 5
          failureThreshold: 3
```

```yaml
# k8s-manifests/overlays/gcp/kustomization.yaml 수정
patches:
  - path: patches/startup-probe-patch.yaml
    target:
      kind: Deployment
```

### Probe 역할 비교

| Probe | 역할 | 실패 시 동작 |
|-------|------|-------------|
| startupProbe | 애플리케이션 최초 시작 완료 확인 | 재시작 (failureThreshold 도달 시) |
| livenessProbe | 애플리케이션 정상 동작 확인 | 재시작 |
| readinessProbe | 트래픽 수신 가능 여부 확인 | Endpoint에서 제거 (재시작 안 함) |

### 검증

```bash
# Probe 설정 확인
kubectl get deployment api-gateway-deployment -n titanium-prod -o yaml | grep -A10 "Probe"

# Pod 시작 이벤트 확인
kubectl describe pod -l app=api-gateway -n titanium-prod | grep -A5 "Events"

# 시작 시간이 긴 Pod 테스트
kubectl rollout restart deployment api-gateway-deployment -n titanium-prod
kubectl get pods -n titanium-prod -w
```

---

## 요약

| ID | 항목 | 난이도 | 예상 시간 | 우선순위 |
|----|------|--------|-----------|----------|
| BP-001 | Terraform Validation | Low | 2시간 | Medium |
| BP-002 | Staging 환경 | High | 8시간 | High |
| BP-003 | Deployment 중복 제거 | Medium | 4시간 | Low |
| BP-004 | External Secrets | High | 8시간 | High |
| BP-005 | startupProbe | Low | 1시간 | Medium |
