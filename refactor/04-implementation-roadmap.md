# Implementation Roadmap

이 문서는 보안 취약점 해결 및 Best Practice 적용을 위한 단계별 구현 로드맵을 제시한다.

---

## 개요

### Phase 구성

| Phase | 목표 | 주요 작업 | 예상 소요 |
|-------|------|----------|-----------|
| Phase 1 | Critical 보안 이슈 해결 | SEC-001, SEC-005 | 2시간 |
| Phase 2 | High 보안 이슈 + 운영 안정성 | SEC-002, BP-001, BP-005 | 8시간 |
| Phase 3 | Medium 이슈 + 아키텍처 개선 | SEC-003, SEC-004, SEC-006, BP-002 | 16시간 |
| Phase 4 | 장기 개선 | BP-003, BP-004 | 16시간 |

---

## Phase 1: Critical 보안 이슈 해결

### 목표
즉시 해결이 필요한 보안 취약점을 수정한다.

### 작업 목록

#### 1.1 SEC-001: CORS Wildcard 수정

**소요 시간**: 30분

**작업 내용**:
```bash
# 1. ConfigMap 수정
vi k8s-manifests/overlays/gcp/configmap-patch.yaml

# 변경: CORS_ALLOWED_ORIGINS: "*" → "https://titanium.example.com"

# 2. 적용 및 검증
kubectl apply -k k8s-manifests/overlays/gcp
kubectl get configmap app-config -n titanium-prod -o yaml | grep CORS
```

**체크리스트**:
- [ ] configmap-patch.yaml 수정
- [ ] kubectl apply 실행
- [ ] CORS 헤더 테스트

---

#### 1.2 SEC-005: Firewall CIDR 제한

**소요 시간**: 1시간

**작업 내용**:
```bash
# 1. 변수 파일 수정
vi terraform/modules/instance/variables.tf

# 2. validation 블록 추가
# 3. terraform plan으로 검증
cd terraform/environments/gcp
terraform plan

# 4. 적용
terraform apply
```

**체크리스트**:
- [ ] variables.tf에 validation 추가
- [ ] terraform.tfvars에 실제 CIDR 설정
- [ ] terraform plan 확인
- [ ] terraform apply 실행
- [ ] 방화벽 규칙 확인

---

### Phase 1 완료 기준

- [ ] CORS가 특정 도메인만 허용
- [ ] 방화벽이 0.0.0.0/0 대신 특정 CIDR만 허용
- [ ] 변경사항 Git 커밋 완료

---

## Phase 2: High 보안 이슈 + 운영 안정성

### 목표
HTTPS 적용 및 기본 운영 안정성을 확보한다.

### 작업 목록

#### 2.1 SEC-002: Istio Gateway HTTPS 설정

**소요 시간**: 4시간

**작업 순서**:

```bash
# Step 1: cert-manager 설치
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s

# Step 2: ClusterIssuer 생성
cat > k8s-manifests/overlays/gcp/istio/cluster-issuer.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: istio
EOF
kubectl apply -f k8s-manifests/overlays/gcp/istio/cluster-issuer.yaml

# Step 3: Certificate 생성
cat > k8s-manifests/overlays/gcp/istio/certificate.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: titanium-cert
  namespace: istio-system
spec:
  secretName: titanium-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - titanium.example.com
EOF
kubectl apply -f k8s-manifests/overlays/gcp/istio/certificate.yaml

# Step 4: Gateway 수정
vi k8s-manifests/overlays/gcp/istio/gateway.yaml
# HTTPS 서버 추가, HTTP → HTTPS 리다이렉트 설정

# Step 5: 적용
kubectl apply -f k8s-manifests/overlays/gcp/istio/gateway.yaml
```

**체크리스트**:
- [ ] cert-manager 설치 완료
- [ ] ClusterIssuer 생성
- [ ] Certificate 발급 확인
- [ ] Gateway HTTPS 설정
- [ ] HTTP → HTTPS 리다이렉트 동작 확인

---

#### 2.2 BP-001: Terraform 변수 Validation

**소요 시간**: 2시간

**작업 내용**:
```bash
# 1. 변수 파일 수정
vi terraform/environments/gcp/variables.tf

# 주요 변수에 validation 추가:
# - cluster_name: 정규식 패턴
# - zone: GCP zone 형식
# - worker_count: 범위 제한
# - machine_type: 허용 목록

# 2. 테스트
terraform plan -var="cluster_name=123"  # 에러 발생 확인
terraform plan -var="worker_count=100"  # 에러 발생 확인
```

**체크리스트**:
- [ ] cluster_name validation 추가
- [ ] zone validation 추가
- [ ] worker_count validation 추가
- [ ] machine_type validation 추가
- [ ] 잘못된 값 입력 시 에러 확인

---

#### 2.3 BP-005: startupProbe 설정

**소요 시간**: 1시간

**작업 내용**:
```bash
# 1. Patch 파일 생성
cat > k8s-manifests/overlays/gcp/patches/startup-probe-patch.yaml << 'EOF'
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
EOF

# 2. kustomization.yaml에 patch 추가
vi k8s-manifests/overlays/gcp/kustomization.yaml

# 3. 적용
kubectl apply -k k8s-manifests/overlays/gcp
```

**체크리스트**:
- [ ] startup-probe-patch.yaml 생성
- [ ] kustomization.yaml에 patch 추가
- [ ] 모든 Deployment에 startupProbe 적용 확인

---

### Phase 2 완료 기준

- [ ] HTTPS로 접속 가능
- [ ] HTTP 요청이 HTTPS로 리다이렉트
- [ ] Terraform validation 동작 확인
- [ ] 모든 Deployment에 startupProbe 적용
- [ ] 변경사항 Git 커밋 완료

---

## Phase 3: Medium 이슈 + 아키텍처 개선

### 목표
보안 강화 및 환경 분리를 완료한다.

### 작업 목록

#### 3.1 SEC-003: RBAC/NetworkPolicy 구현

**소요 시간**: 4시간

**작업 순서**:

```bash
# Step 1: RBAC 디렉토리 생성
mkdir -p k8s-manifests/overlays/gcp/rbac

# Step 2: ServiceAccount 생성
cat > k8s-manifests/overlays/gcp/rbac/serviceaccounts.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-gateway-sa
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: user-service-sa
# ... (다른 서비스도 동일하게)
EOF

# Step 3: Role/RoleBinding 생성
# Step 4: NetworkPolicy 생성
# Step 5: Deployment에 ServiceAccount 적용

# Step 6: kustomization.yaml에 리소스 추가
vi k8s-manifests/overlays/gcp/kustomization.yaml

# Step 7: 적용
kubectl apply -k k8s-manifests/overlays/gcp
```

**체크리스트**:
- [ ] ServiceAccount 생성
- [ ] Role/RoleBinding 생성
- [ ] NetworkPolicy 생성
- [ ] Deployment에 ServiceAccount 연결
- [ ] 권한 테스트 (불필요한 API 호출 차단 확인)

---

#### 3.2 SEC-004: PostgreSQL SSL 활성화

**소요 시간**: 2시간

**작업 순서**:

```bash
# Step 1: SSL 인증서 생성
openssl req -new -x509 -days 365 -nodes \
  -out server.crt -keyout server.key \
  -subj "/CN=postgresql-service"

# Step 2: Secret 생성
kubectl create secret tls postgres-tls \
  -n titanium-prod \
  --cert=server.crt \
  --key=server.key

# Step 3: StatefulSet 수정
vi k8s-manifests/overlays/gcp/postgres/statefulset.yaml

# Step 4: ConfigMap 수정
vi k8s-manifests/overlays/gcp/kustomization.yaml
# POSTGRES_SSLMODE=disable → require

# Step 5: 적용
kubectl apply -k k8s-manifests/overlays/gcp
```

**체크리스트**:
- [ ] SSL 인증서 생성
- [ ] postgres-tls Secret 생성
- [ ] StatefulSet에 SSL 설정 추가
- [ ] SSLMODE=require 설정
- [ ] 애플리케이션 연결 테스트

---

#### 3.3 SEC-006: kubeconfig TLS 검증 활성화

**소요 시간**: 2시간

**작업 순서**:

```bash
# Step 1: 스크립트 생성
cat > terraform/environments/gcp/scripts/get-kubeconfig.sh << 'EOF'
#!/bin/bash
MASTER_IP=$1
SSH_KEY=${2:-~/.ssh/id_rsa}

ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$MASTER_IP \
  "sudo cat /etc/rancher/k3s/k3s.yaml" > ~/.kube/config-gcp-secure

sed -i '' "s/127.0.0.1/$MASTER_IP/g" ~/.kube/config-gcp-secure
echo "Secure kubeconfig created at ~/.kube/config-gcp-secure"
EOF

chmod +x terraform/environments/gcp/scripts/get-kubeconfig.sh

# Step 2: Terraform output 수정
vi terraform/environments/gcp/outputs.tf

# Step 3: 사용
./scripts/get-kubeconfig.sh <MASTER_IP>
```

**체크리스트**:
- [ ] get-kubeconfig.sh 스크립트 생성
- [ ] outputs.tf에 사용 방법 추가
- [ ] Secure kubeconfig 생성 테스트
- [ ] kubectl 연결 테스트

---

#### 3.4 BP-002: Staging 환경 구성

**소요 시간**: 8시간

**작업 순서**:

```bash
# Step 1: Terraform Staging 환경 생성
mkdir -p terraform/environments/staging
cp terraform/environments/gcp/*.tf terraform/environments/staging/

# Step 2: Staging 변수 수정
vi terraform/environments/staging/terraform.tfvars
# cluster_name = "titanium-staging"
# worker_count = 1
# master_machine_type = "e2-small"

# Step 3: Kubernetes Staging Overlay 생성
mkdir -p k8s-manifests/overlays/staging
# kustomization.yaml, namespace.yaml 생성

# Step 4: ArgoCD Staging Application 추가
# Step 5: CI/CD Pipeline 수정
```

**체크리스트**:
- [ ] Terraform staging 환경 생성
- [ ] staging terraform.tfvars 설정
- [ ] Kubernetes staging overlay 생성
- [ ] ArgoCD staging application 추가
- [ ] CI/CD pipeline 수정
- [ ] Staging 배포 테스트

---

### Phase 3 완료 기준

- [ ] RBAC/NetworkPolicy 적용 완료
- [ ] PostgreSQL SSL 연결 동작
- [ ] Secure kubeconfig 사용 가능
- [ ] Staging 환경 배포 가능
- [ ] 변경사항 Git 커밋 완료

---

## Phase 4: 장기 개선

### 목표
코드 품질 및 보안 자동화를 완성한다.

### 작업 목록

#### 4.1 BP-003: Deployment 템플릿화

**소요 시간**: 8시간

**작업 옵션**:

**Option A: Kustomize Components**
```bash
# 공통 설정을 Component로 분리
mkdir -p k8s-manifests/components/standard-deployment
# Component YAML 생성
# kustomization.yaml에서 components 참조
```

**Option B: Helm Chart 전환**
```bash
# Helm Chart 구조 생성
mkdir -p charts/titanium-service/templates
# Chart.yaml, values.yaml, deployment.yaml 생성
# ArgoCD에서 Helm source 사용
```

**체크리스트**:
- [ ] 공통 설정 추출
- [ ] 템플릿/Component 생성
- [ ] 기존 Deployment 마이그레이션
- [ ] 동작 테스트

---

#### 4.2 BP-004: External Secrets Operator 도입

**소요 시간**: 8시간

**작업 순서**:

```bash
# Step 1: External Secrets Operator 설치
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

# Step 2: GCP Secret Manager에 Secret 생성
gcloud secrets create postgres-password --data-file=-
gcloud secrets create jwt-secret-key --data-file=-

# Step 3: SecretStore 생성
# Step 4: ExternalSecret 생성
# Step 5: 기존 Secret 제거
```

**체크리스트**:
- [ ] External Secrets Operator 설치
- [ ] GCP Secret Manager에 Secret 저장
- [ ] SecretStore 생성
- [ ] ExternalSecret 생성
- [ ] 기존 Secret 파일 제거
- [ ] 애플리케이션 동작 테스트

---

### Phase 4 완료 기준

- [ ] Deployment 중복 제거
- [ ] External Secrets 동작
- [ ] Git에 Secret 미저장
- [ ] 전체 시스템 동작 테스트 완료

---

## 전체 일정 요약

```
Week 1
├── Day 1: Phase 1 완료 (2시간)
├── Day 2-3: Phase 2 완료 (8시간)
│
Week 2
├── Day 1-2: Phase 3 SEC 항목 (8시간)
├── Day 3-4: Phase 3 BP-002 Staging (8시간)
│
Week 3-4
├── Phase 4 장기 개선 (16시간)
└── 최종 테스트 및 문서화
```

---

## 검증 체크리스트

### 보안 검증

```bash
# CORS 테스트
curl -I -X OPTIONS https://api.titanium.example.com \
  -H "Origin: https://malicious.com"

# HTTPS 테스트
curl -v https://titanium.example.com

# RBAC 테스트
kubectl auth can-i get pods --as=system:serviceaccount:titanium-prod:api-gateway-sa -n titanium-prod

# NetworkPolicy 테스트
kubectl exec -it <pod> -- curl http://unauthorized-service:8080
```

### 운영 검증

```bash
# Pod 시작 테스트 (startupProbe)
kubectl rollout restart deployment -n titanium-prod
kubectl get pods -n titanium-prod -w

# Staging 환경 테스트
KUBECONFIG=~/.kube/config-staging kubectl get pods -n titanium-staging

# External Secrets 동기화
kubectl get externalsecret -n titanium-prod
```

---

## 롤백 계획

### Phase별 롤백 방법

| Phase | 롤백 방법 |
|-------|----------|
| Phase 1 | `git revert` 후 `kubectl apply` |
| Phase 2 | cert-manager 삭제, Gateway 이전 버전 적용 |
| Phase 3 | RBAC/NetworkPolicy 삭제, Staging 환경 삭제 |
| Phase 4 | External Secrets 삭제, 기존 Secret 복원 |

```bash
# Git 기반 롤백
git log --oneline
git revert <commit-hash>
kubectl apply -k k8s-manifests/overlays/gcp

# ArgoCD 롤백
argocd app history titanium-prod
argocd app rollback titanium-prod <revision>
```
