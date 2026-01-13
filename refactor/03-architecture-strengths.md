# Architecture Strengths

이 문서는 현재 인프라 코드에서 잘 구현된 부분을 분석하여 유지보수 및 확장 시 참고할 수 있도록 정리한다.

---

## 목차

1. [STR-001: mTLS STRICT 모드 적용](#str-001-mtls-strict-모드-적용)
2. [STR-002: IAM 최소 권한 원칙](#str-002-iam-최소-권한-원칙)
3. [STR-003: Shielded VM 설정](#str-003-shielded-vm-설정)
4. [STR-004: Kustomize base/overlay 패턴](#str-004-kustomize-baseoverlay-패턴)
5. [STR-005: GitOps 자동화 (ArgoCD)](#str-005-gitops-자동화-argocd)

---

## STR-001: mTLS STRICT 모드 적용

### 평가: 양호

### 구현 현황

**파일**: `k8s-manifests/overlays/gcp/istio/peer-authentication.yaml`

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-mtls
  namespace: titanium-prod
spec:
  mtls:
    mode: STRICT
```

모든 서비스 간 통신에 상호 TLS(mTLS)가 강제 적용되어 있다.

### 장점

1. **Zero Trust 보안**: 서비스 간 통신이 자동으로 암호화되어 내부 네트워크에서도 데이터 보호
2. **서비스 인증**: 모든 서비스가 인증서 기반으로 상호 인증
3. **중간자 공격 방지**: TLS 암호화로 패킷 스니핑 차단
4. **Istio 자동 관리**: 인증서 발급, 갱신, 배포가 자동화

### 관련 설정

**DestinationRule (TLS 설정)**:
```yaml
# k8s-manifests/overlays/gcp/istio/destination-rules.yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: default-destination-rule
spec:
  host: "*.titanium-prod.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

**Database 예외 처리**:
```yaml
# k8s-manifests/overlays/gcp/istio/peer-authentication-databases.yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: postgresql-mtls-disable
spec:
  selector:
    matchLabels:
      app: postgresql
  mtls:
    mode: DISABLE
```

PostgreSQL, Redis 등 데이터베이스는 mTLS를 비활성화하여 호환성을 유지한다.

### 검증

```bash
# mTLS 상태 확인
istioctl x authz check <pod-name> -n titanium-prod

# 서비스 간 TLS 연결 확인
kubectl exec -it <source-pod> -n titanium-prod -- \
  curl -v http://prod-user-service:8001/health 2>&1 | grep "SSL"

# Kiali에서 mTLS 아이콘 확인
# 잠금 아이콘이 표시되면 mTLS 활성화 상태
```

---

## STR-002: IAM 최소 권한 원칙

### 평가: 양호

### 구현 현황

**파일**: `terraform/environments/gcp/main.tf:69-86`

```hcl
# Service Account for k3s cluster (minimum privilege)
resource "google_service_account" "k3s_sa" {
  account_id   = "${var.cluster_name}-sa"
  display_name = "Service Account for K3s Cluster"
}

# IAM Role Bindings for logging and monitoring
resource "google_project_iam_member" "sa_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.k3s_sa.email}"
}

resource "google_project_iam_member" "sa_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.k3s_sa.email}"
}
```

k3s 클러스터 VM에 최소한의 GCP 권한만 부여되어 있다.

### 장점

1. **최소 권한 원칙 준수**: 필요한 권한(Logging, Monitoring)만 부여
2. **권한 분리**: 클러스터별 별도 Service Account 사용
3. **감사 추적**: Service Account 단위로 API 호출 추적 가능
4. **침해 범위 제한**: VM이 침해되어도 GCP 리소스 접근 제한

### 부여된 권한 분석

| 역할 | 권한 | 용도 |
|------|------|------|
| `roles/logging.logWriter` | 로그 쓰기 | Cloud Logging으로 컨테이너 로그 전송 |
| `roles/monitoring.metricWriter` | 메트릭 쓰기 | Cloud Monitoring으로 메트릭 전송 |

**부여되지 않은 위험 권한**:
- `roles/compute.admin`: VM 관리 불가
- `roles/storage.admin`: GCS 버킷 관리 불가
- `roles/iam.serviceAccountAdmin`: SA 관리 불가

### 검증

```bash
# Service Account 권한 확인
gcloud projects get-iam-policy ${PROJECT_ID} \
  --filter="bindings.members:serviceAccount:titanium-k3s-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --format="table(bindings.role)"

# 예상 결과:
# ROLE
# roles/logging.logWriter
# roles/monitoring.metricWriter
```

---

## STR-003: Shielded VM 설정

### 평가: 양호

### 구현 현황

**파일**: `terraform/environments/gcp/main.tf:211-215`

```hcl
# Master Node
shielded_instance_config {
  enable_secure_boot          = true
  enable_vtpm                 = true
  enable_integrity_monitoring = true
}
```

**파일**: `terraform/environments/gcp/mig.tf:61-65`

```hcl
# Worker Node Template
shielded_instance_config {
  enable_secure_boot          = true
  enable_vtpm                 = true
  enable_integrity_monitoring = true
}
```

Master와 Worker 모든 노드에 Shielded VM 기능이 활성화되어 있다.

### 장점

1. **Secure Boot**: 서명되지 않은 부트로더/커널 실행 차단
2. **vTPM (Virtual Trusted Platform Module)**: 암호화 키 및 무결성 데이터 저장
3. **Integrity Monitoring**: 부팅 프로세스 무결성 검증 및 알림
4. **Rootkit 방지**: 부팅 단계에서 악성코드 주입 차단

### 보안 기능 상세

| 기능 | 설명 | 보호 대상 |
|------|------|-----------|
| Secure Boot | UEFI 펌웨어가 서명된 코드만 실행 | 부트로더, 커널 |
| vTPM | 암호화 작업 및 키 저장 | 디스크 암호화 키, 인증서 |
| Integrity Monitoring | 부팅 구성요소 해시 검증 | 펌웨어, 부트로더, 커널 |

### 검증

```bash
# Shielded VM 상태 확인
gcloud compute instances describe titanium-k3s-master \
  --zone=asia-northeast3-a \
  --format="yaml(shieldedInstanceConfig)"

# 예상 결과:
# shieldedInstanceConfig:
#   enableIntegrityMonitoring: true
#   enableSecureBoot: true
#   enableVtpm: true

# Integrity Monitoring 이벤트 확인
gcloud compute instances get-shielded-identity titanium-k3s-master \
  --zone=asia-northeast3-a
```

---

## STR-004: Kustomize base/overlay 패턴

### 평가: 양호

### 구현 현황

```
k8s-manifests/
├── base/                          # 기본 리소스 정의
│   ├── kustomization.yaml
│   ├── api-gateway-deployment.yaml
│   ├── api-gateway-service.yaml
│   ├── user-service-deployment.yaml
│   ├── auth-service-deployment.yaml
│   ├── blog-service-deployment.yaml
│   ├── redis-deployment.yaml
│   ├── configmap.yaml
│   └── secret.yaml
│
├── monitoring/                    # 모니터링 스택
│   ├── prometheus-values.yaml
│   └── loki-stack-values.yaml
│
└── overlays/
    ├── local/                     # 로컬 개발 환경
    │   ├── kustomization.yaml
    │   └── namespace.yaml
    │
    └── gcp/                       # GCP Production 환경
        ├── kustomization.yaml
        ├── namespace.yaml
        ├── configmap-patch.yaml
        ├── postgres/
        ├── istio/
        └── patches/
```

### 장점

1. **DRY 원칙**: 기본 리소스를 base에 정의하고 환경별 차이만 overlay에서 관리
2. **환경 분리**: local/gcp 환경의 설정을 명확히 구분
3. **변경 추적**: Git으로 환경별 설정 변경 이력 관리
4. **재사용성**: 새 환경 추가 시 overlay만 생성하면 됨

### Kustomize 기능 활용 현황

**파일**: `k8s-manifests/overlays/gcp/kustomization.yaml`

```yaml
# 네임스페이스 자동 적용
namespace: titanium-prod

# 이름 접두사 추가
namePrefix: prod-

# 이미지 태그 관리
images:
  - name: dongju101/user-service
    newTag: main-b1a60a7

# Replica 수 조정
replicas:
  - name: user-service-deployment
    count: 2

# ConfigMap 병합
configMapGenerator:
  - name: app-config
    behavior: merge
    literals:
      - ENVIRONMENT=production

# 공통 라벨 적용
labels:
  - pairs:
      environment: production
      managed-by: kustomize
```

### 환경별 차이점

| 항목 | local | gcp |
|------|-------|-----|
| Namespace | titanium-local | titanium-prod |
| Prefix | - | prod- |
| Replicas | 1 | 2 |
| Environment | development | production |
| Log Level | DEBUG | INFO |
| Istio | 없음 | mTLS STRICT |
| PostgreSQL | SQLite | PostgreSQL |

### 검증

```bash
# Kustomize 빌드 테스트
kustomize build k8s-manifests/overlays/gcp > /tmp/gcp-manifests.yaml
kustomize build k8s-manifests/overlays/local > /tmp/local-manifests.yaml

# 차이점 확인
diff /tmp/gcp-manifests.yaml /tmp/local-manifests.yaml | head -50

# 리소스 수 비교
grep "kind:" /tmp/gcp-manifests.yaml | sort | uniq -c
grep "kind:" /tmp/local-manifests.yaml | sort | uniq -c
```

---

## STR-005: GitOps 자동화 (ArgoCD)

### 평가: 양호

### 구현 현황

**Terraform ArgoCD 모듈**: `terraform/modules/argocd/`

```hcl
# Helm으로 ArgoCD 설치
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  set {
    name  = "server.service.type"
    value = "NodePort"
  }
}
```

**ArgoCD Application 정의**: `terraform/modules/argocd-apps/`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: titanium-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/DvwN-Lee/Monitoring-v3.git
    targetRevision: main
    path: k8s-manifests/overlays/gcp
  destination:
    server: https://kubernetes.default.svc
    namespace: titanium-prod
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 장점

1. **Single Source of Truth**: Git 리포지토리가 배포 상태의 유일한 진실
2. **자동 동기화**: Git 변경 시 자동으로 클러스터에 반영
3. **Self-Healing**: 수동 변경 시 Git 상태로 자동 복구
4. **감사 추적**: Git 커밋 이력으로 모든 변경 추적
5. **롤백 용이**: Git revert로 즉시 이전 상태 복원

### GitOps 워크플로우

```
Developer → Git Push → GitHub Actions (CI) → Docker Hub →
GitHub Actions (CD) → kustomization.yaml 업데이트 → Git Push →
ArgoCD (Auto Sync) → Kubernetes Cluster
```

### CI/CD Pipeline 연동

**파일**: `.github/workflows/cd.yml`

```yaml
- name: Update Kustomize image tags
  run: |
    cd k8s-manifests/overlays/gcp
    kustomize edit set image dongju101/${{ matrix.service }}:main-${{ github.sha }}

- name: Commit and push changes
  run: |
    git add k8s-manifests/overlays/gcp/kustomization.yaml
    git commit -m "chore: Update ${{ matrix.service }} image to main-${{ github.sha }} [skip ci]"
    git push
```

### ArgoCD 동기화 정책

| 정책 | 설정 | 효과 |
|------|------|------|
| `automated.prune` | true | Git에서 삭제된 리소스 자동 삭제 |
| `automated.selfHeal` | true | 수동 변경 시 Git 상태로 복구 |
| `syncPolicy.syncOptions` | - | 동기화 옵션 (CreateNamespace 등) |

### 검증

```bash
# ArgoCD Application 상태 확인
kubectl get applications -n argocd

# 동기화 상태 상세 확인
argocd app get titanium-prod

# 동기화 이력 확인
argocd app history titanium-prod

# 수동 동기화 테스트
argocd app sync titanium-prod

# Self-heal 테스트
kubectl scale deployment prod-api-gateway-deployment -n titanium-prod --replicas=5
# 잠시 후 ArgoCD가 replica를 2로 복원하는지 확인
kubectl get deployment prod-api-gateway-deployment -n titanium-prod -w
```

---

## 요약

| ID | 항목 | 카테고리 | 평가 |
|----|------|----------|------|
| STR-001 | mTLS STRICT 모드 | 보안 | 양호 |
| STR-002 | IAM 최소 권한 | 보안 | 양호 |
| STR-003 | Shielded VM | 보안 | 양호 |
| STR-004 | Kustomize 패턴 | 운영 | 양호 |
| STR-005 | GitOps (ArgoCD) | 자동화 | 양호 |

### 유지보수 권장사항

1. **mTLS**: Database 예외 처리가 필요한 경우 PeerAuthentication으로 세밀하게 제어
2. **IAM**: 새로운 기능 추가 시 필요한 최소 권한만 부여
3. **Shielded VM**: 모든 새 VM에 동일한 보안 설정 적용
4. **Kustomize**: 새 환경 추가 시 overlay 패턴 유지
5. **ArgoCD**: Application 추가 시 syncPolicy 일관성 유지
