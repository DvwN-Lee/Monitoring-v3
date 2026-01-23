# Terraform GCP Setup Guide

## 사전 요구사항

1. GCP 프로젝트 생성
2. Billing Account 연결
3. gcloud CLI 설치 및 인증

## Service Account 설정

Terraform 실행을 위한 Service Account를 생성하고 인증을 설정합니다.

### 1. Service Account 생성

```bash
# Project ID 설정
export PROJECT_ID="your-project-id"

# Service Account 생성
gcloud iam service-accounts create terraform-sa \
  --display-name="Terraform Service Account" \
  --project=${PROJECT_ID}
```

### 2. IAM 권한 부여

```bash
# Owner 역할 부여 (개발 환경)
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:terraform-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/owner"
```

**프로덕션 환경**에서는 최소 권한 원칙에 따라 다음 역할만 부여:
- `roles/compute.admin`
- `roles/iam.serviceAccountAdmin`
- `roles/resourcemanager.projectIamAdmin`

### 3. Service Account Key 생성

```bash
# Key 파일 생성
gcloud iam service-accounts keys create ~/terraform-sa-key.json \
  --iam-account=terraform-sa@${PROJECT_ID}.iam.gserviceaccount.com

# 환경변수 설정
export GOOGLE_APPLICATION_CREDENTIALS=~/terraform-sa-key.json
```

**중요**: Service Account Key 파일은 민감 정보이므로 Git repository에 포함하지 마세요.

### 4. .gitignore 확인

```bash
# terraform-sa-key.json이 .gitignore에 포함되어 있는지 확인
cat .gitignore | grep "terraform-sa-key.json"
```

## Remote State Backend 설정

### 1. GCS Bucket 생성

```bash
# Bucket 이름 설정 (globally unique해야 함)
export BUCKET_NAME="${PROJECT_ID}-terraform-state"

# Bucket 생성
gcloud storage buckets create gs://${BUCKET_NAME} \
  --project=${PROJECT_ID} \
  --location=asia-northeast3 \
  --uniform-bucket-level-access

# Versioning 활성화 (state 파일 복구용)
gcloud storage buckets update gs://${BUCKET_NAME} \
  --versioning
```

### 2. Backend 초기화

```bash
cd terraform/environments/gcp

# backend.tf 파일에서 bucket 이름 확인
# terraform init으로 backend 초기화
terraform init
```

### 3. Local State에서 마이그레이션

기존 local state가 있는 경우:

```bash
# State 파일 백업
cp terraform.tfstate terraform.tfstate.backup

# Backend 설정 후 마이그레이션
terraform init -migrate-state
```

## 프로젝트 전환 시 절차

다른 GCP 프로젝트로 전환할 때:

### 1. 환경변수 업데이트

```bash
export PROJECT_ID="new-project-id"
export GOOGLE_APPLICATION_CREDENTIALS=~/terraform-sa-key-new.json
```

### 2. terraform.tfvars 수정

```hcl
project_id = "new-project-id"
region     = "asia-northeast3"
zone       = "asia-northeast3-a"
```

### 3. Backend 재초기화

```bash
# 기존 .terraform 디렉토리 삭제
rm -rf .terraform

# 새 프로젝트로 초기화
terraform init -reconfigure
```

## 환경별 변수 관리

환경별(dev, staging, prod)로 변수를 분리하여 관리:

```
terraform/environments/gcp/
├── terraform.tfvars.example     # 템플릿
├── dev.tfvars                   # 개발 환경
├── staging.tfvars               # 스테이징 환경
└── prod.tfvars                  # 프로덕션 환경
```

배포 시 환경별 변수 파일 지정:

```bash
terraform plan -var-file="dev.tfvars"
terraform apply -var-file="prod.tfvars"
```

## 문제 해결

### API not enabled 오류

```
Error: Error creating Network: googleapi: Error 403: Compute Engine API has not been used
```

**해결**: `api-services.tf`에 정의된 API들이 자동으로 활성화됩니다. Terraform apply 재실행.

### Permission denied 오류

```
Error: Error creating service account: googleapi: Error 403: Permission denied
```

**해결**:
1. Service Account에 적절한 IAM 역할이 부여되었는지 확인
2. `GOOGLE_APPLICATION_CREDENTIALS` 환경변수가 올바른 key 파일을 가리키는지 확인

### State lock 오류

```
Error: Error acquiring the state lock
```

**해결**:
```bash
# Force unlock (주의: 다른 사용자가 실행 중이지 않은지 확인 후 실행)
terraform force-unlock <LOCK_ID>
```

## 보안 권장사항

1. Service Account Key는 안전한 위치에 저장 (`~/.gcp/` 디렉토리 권장)
2. Key 파일 권한 제한: `chmod 600 ~/terraform-sa-key.json`
3. 정기적으로 Key 교체 (90일마다 권장)
4. 프로덕션 환경에서는 Workload Identity 사용 고려
5. terraform.tfvars에 민감 정보 하드코딩 금지 (환경변수 사용)
