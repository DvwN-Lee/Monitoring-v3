# Solid Cloud Overlay

Solid Cloud 프로덕션 환경을 위한 Kustomize overlay입니다.

## 설정 방법

### 1. Secret 파일 생성

**중요**: `secret-patch.yaml` 파일은 보안을 위해 gitignore에 포함되어 있습니다. 수동으로 생성해야 합니다:

```bash
cd k8s-manifests/overlays/solid-cloud

# 예제 파일 복사
cp secret-patch.yaml.example secret-patch.yaml

# 실제 값으로 편집
vi secret-patch.yaml
```

### 2. Base64 인코딩된 Secret 생성

```bash
# PostgreSQL User
echo -n "postgres" | base64
# Output: cG9zdGdyZXM=

# PostgreSQL Password (강력한 비밀번호 사용!)
echo -n "YOUR_SECURE_PASSWORD_HERE" | base64

# JWT Secret Key
echo -n "production-jwt-secret-key-$(openssl rand -hex 32)" | base64

# Internal API Secret
echo -n "production-api-secret-$(openssl rand -hex 32)" | base64
```

### 3. secret-patch.yaml 업데이트

`secret-patch.yaml` 파일의 placeholder 값을 생성한 base64 값으로 교체합니다.

### 4. Kubernetes에 배포

```bash
# 프로젝트 루트에서 실행
kubectl apply -k k8s-manifests/overlays/solid-cloud

# 배포 확인
kubectl get pods -n titanium-prod
kubectl get svc -n titanium-prod
```

## 구성 내용

### Namespace
- `titanium-prod`: 프로덕션 Namespace

### ConfigMap Patches
- PostgreSQL 연결 설정
- 프로덕션 서비스 URL (`prod-` 접두사 포함)
- 환경 설정: `production`

### Secret Patches
- PostgreSQL 자격 증명
- JWT 서명 키
- 내부 API 시크릿

### Service Patches
- 외부 접근을 위한 Load Balancer 서비스 타입

### Deployment Patches
- user-service PostgreSQL 환경 변수
- blog-service PostgreSQL 환경 변수
- SQLite 볼륨 및 마운트 제거

## 테스트

```bash
# PostgreSQL 연결 테스트
kubectl exec -it postgresql-0 -n titanium-prod -- psql -U postgres -d titanium

# Service Endpoint 확인
kubectl get svc -n titanium-prod

# 로그 확인
kubectl logs -f deployment/prod-user-service-deployment -n titanium-prod
kubectl logs -f deployment/prod-blog-service-deployment -n titanium-prod
```

## 업데이트

```bash
# 매니페스트 변경 후
kubectl apply -k k8s-manifests/overlays/solid-cloud

# 강제 롤아웃 재시작
kubectl rollout restart deployment/prod-user-service-deployment -n titanium-prod
kubectl rollout restart deployment/prod-blog-service-deployment -n titanium-prod
```

## 정리

```bash
# 모든 리소스 삭제
kubectl delete -k k8s-manifests/overlays/solid-cloud

# Namespace 삭제 (내부 모든 리소스 삭제)
kubectl delete namespace titanium-prod
```

## 보안 주의사항

- **`secret-patch.yaml`을 절대 버전 관리 시스템에 커밋하지 마세요**
- 강력하고 무작위로 생성된 비밀번호 사용
- 정기적으로 시크릿 교체
- Kubernetes RBAC를 사용하여 시크릿 접근 제한
- 외부 시크릿 관리 도구 사용 고려 (예: Vault, AWS Secrets Manager)
