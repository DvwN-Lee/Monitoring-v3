# Operational Changes Log

이 문서는 운영 중 발생한 주요 변경사항을 기록합니다. GitOps 저장소에 반영되지 않은 직접 변경사항(kubectl 직접 적용 등)을 중점적으로 기록합니다.

## 2026-01-21: Secret 수정 (kubectl 직접 적용)

### 배경

Application Pod가 CrashLoopBackOff 상태로 시작 실패했습니다. 로그 분석 결과 Secret에 placeholder 값이 사용되어 Application이 정상적으로 초기화되지 못했습니다.

**발견된 문제**:
- JWT_PRIVATE_KEY: `placeholder-private-key` (유효하지 않은 RSA 키)
- JWT_PUBLIC_KEY: `placeholder-public-key` (유효하지 않은 RSA 키)
- POSTGRES_PASSWORD: `TempPassword123!` (실제 PostgreSQL 비밀번호와 불일치)

### 변경 내용

#### 1. JWT 키 쌍 생성 및 적용

**RSA 2048 키 쌍 생성**:
```bash
# Private key 생성
openssl genrsa -out jwt_private.pem 2048

# Public key 추출
openssl rsa -in jwt_private.pem -pubout -out jwt_public.pem
```

**생성된 키 크기**:
- JWT_PRIVATE_KEY: 1704 bytes (RSA 2048 private key)
- JWT_PUBLIC_KEY: 451 bytes (RSA 2048 public key)

#### 2. POSTGRES_PASSWORD 동기화

**Before**: `TempPassword123!` (placeholder)
**After**: 실제 PostgreSQL 비밀번호로 동기화 (`postgresql-secret`의 POSTGRES_PASSWORD와 일치)

**동기화 방법**:
```bash
# postgresql-secret에서 실제 비밀번호 확인
kubectl get secret postgresql-secret -n titanium-prod -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d

# prod-app-secrets에 동일한 비밀번호 적용
```

### 적용 방법

**kubectl patch 명령 사용**:
```bash
# Base64 인코딩
JWT_PRIVATE_BASE64=$(cat jwt_private.pem | base64)
JWT_PUBLIC_BASE64=$(cat jwt_public.pem | base64)
POSTGRES_PASSWORD_BASE64=$(kubectl get secret postgresql-secret -n titanium-prod -o jsonpath='{.data.POSTGRES_PASSWORD}')

# Secret patch
kubectl patch secret prod-app-secrets -n titanium-prod --type=json -p='[
  {"op": "replace", "path": "/data/JWT_PRIVATE_KEY", "value": "'$JWT_PRIVATE_BASE64'"},
  {"op": "replace", "path": "/data/JWT_PUBLIC_KEY", "value": "'$JWT_PUBLIC_BASE64'"},
  {"op": "replace", "path": "/data/POSTGRES_PASSWORD", "value": "'$POSTGRES_PASSWORD_BASE64'"}
]'
```

### Deployment 재시작

Secret 수정 후 모든 Application Deployment를 재시작하여 새로운 Secret 값을 적용했습니다.

```bash
# User Service
kubectl rollout restart deployment prod-user-service-deployment -n titanium-prod

# Auth Service
kubectl rollout restart deployment prod-auth-service-deployment -n titanium-prod

# Blog Service
kubectl rollout restart deployment prod-blog-service-deployment -n titanium-prod

# API Gateway
kubectl rollout restart deployment prod-api-gateway-deployment -n titanium-prod
```

### 검증

**1. Secret 값 확인**:
```bash
kubectl describe secret prod-app-secrets -n titanium-prod
```

**결과**:
- JWT_PRIVATE_KEY: 1704 bytes (RSA 키로 확인)
- JWT_PUBLIC_KEY: 451 bytes (RSA 키로 확인)
- POSTGRES_PASSWORD: 16 bytes (실제 비밀번호)

**2. Pod 상태 확인**:
```bash
kubectl get pods -n titanium-prod
```

**결과**:
- 모든 Application Pod: 2/2 Running
- RESTARTS: 0
- 11시간 이상 안정적으로 실행 중

**3. Application Health Check**:
```bash
# User Service
kubectl exec -n titanium-prod <pod> -c user-service-container -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8001/health').read().decode())"

# Auth Service
kubectl exec -n titanium-prod <pod> -c auth-service-container -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8002/health').read().decode())"

# Blog Service
kubectl exec -n titanium-prod <pod> -c blog-service-container -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8005/health').read().decode())"
```

**결과**:
- User Service: `{"status":"healthy"}`
- Auth Service: `{"status":"ok","service":"auth-service"}`
- Blog Service: `{"status":"ok","service":"blog-service"}`

### 영향 범위

**영향 받는 리소스**:
- Secret: `prod-app-secrets` (titanium-prod namespace)
- Deployment: `prod-user-service-deployment`
- Deployment: `prod-auth-service-deployment`
- Deployment: `prod-blog-service-deployment`
- Deployment: `prod-api-gateway-deployment`

**다운타임**:
- 약 2-3분 (Rolling update 중 일시적)
- 각 Deployment는 2개 replica로 동작하여 1개씩 순차 재시작
- 서비스 중단 없음 (최소 1개 Pod는 항상 Running 상태 유지)

### 후속 조치 (완료)

본 이슈 이후 External Secrets Operator + GCP Secret Manager 기반 Secret 관리 체계가 구축되었다. 상세 내용은 [Secret Management](secret-management.md) 문서 참조.

### 향후 권장사항

#### 1. Secret 값 검증 자동화

**Pre-deployment 검증**:
- Secret 값이 placeholder인지 자동 검증
- CI/CD pipeline에 검증 단계 추가
- ArgoCD PreSync hook 활용

**검증 스크립트 예시**:
```bash
#!/bin/bash
# Validate Secret values are not placeholders

SECRET_NAME="prod-app-secrets"
NAMESPACE="titanium-prod"

# Check JWT keys
JWT_PRIVATE=$(kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.JWT_PRIVATE_KEY}' | base64 -d)
if [[ "$JWT_PRIVATE" == *"placeholder"* ]]; then
  echo "ERROR: JWT_PRIVATE_KEY is placeholder"
  exit 1
fi

# Check POSTGRES_PASSWORD
POSTGRES_PASS=$(kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
if [[ "$POSTGRES_PASS" == "TempPassword123!" ]]; then
  echo "ERROR: POSTGRES_PASSWORD is placeholder"
  exit 1
fi

echo "Secret validation passed"
```

#### 2. 문서화

**Secret 관리 절차 문서화**:
- Secret 생성 절차
- Secret rotation 절차
- Secret 백업 및 복구 절차

**Troubleshooting 가이드 업데이트**:
- Secret 관련 일반적인 오류 및 해결 방법
- Pod CrashLoopBackOff 디버깅 절차

### 관련 이슈 및 PR

- **Issue #68**: istio-proxy CSR 서명 실패 (관련성: Secret 문제로 인한 Pod 재시작 발생)
- **Issue #70**: NetworkPolicy Istiod egress 누락 (관련성: Pod 재배포 시 NetworkPolicy 검증 필요)
- **PR #69**: istio-proxy graceful shutdown 설정 추가
- **PR #71**: NetworkPolicy Istiod egress 규칙 추가

### 참고 문서

- Kubernetes Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- External Secrets Operator: https://external-secrets.io/
- ArgoCD Sync Hooks: https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/
- OpenSSL RSA Key Generation: https://www.openssl.org/docs/man1.1.1/man1/genrsa.html

---

## 변경 이력 템플릿

향후 운영 변경사항은 다음 형식으로 기록합니다:

```markdown
## YYYY-MM-DD: [변경 제목]

### 배경
[변경이 필요한 이유 및 문제 상황]

### 변경 내용
[구체적인 변경 사항]

### 적용 방법
[변경을 적용한 방법 (명령어 포함)]

### 검증
[변경 후 검증 방법 및 결과]

### 영향 범위
[영향 받는 리소스 및 서비스]

### 향후 권장사항
[재발 방지 또는 개선 방안]

### 관련 이슈 및 PR
[관련 GitHub Issue 및 PR 링크]
```
