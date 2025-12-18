# Terratest for GCP k3s Monitoring Stack

이 디렉토리는 GCP k3s infrastructure와 monitoring stack의 자동화된 테스트를 포함합니다.

## 사전 요구사항

### 1. Go 설치
```bash
# macOS
brew install go

# 버전 확인
go version  # go1.21 이상 권장
```

### 2. GCP 인증 설정
```bash
# GCP 인증
gcloud auth application-default login

# 프로젝트 설정
gcloud config set project titanium-k3s-1765951764
```

### 3. 환경 변수 설정
```bash
export GOOGLE_PROJECT="titanium-k3s-1765951764"
export GOOGLE_REGION="asia-northeast3"
export GOOGLE_ZONE="asia-northeast3-a"
```

## 테스트 종류

### 1. Basic Unit Tests (빠른 검증)
- Terraform 구문 검증
- Variable validation
- Plan 생성 테스트
- **실제 리소스 생성 없음**

```bash
cd test
go mod download
go test -v -run TestTerraformBasicValidation -timeout 10m
```

### 2. Integration Tests (실제 배포)
- 실제 GCP 리소스 생성
- k3s cluster 배포 및 검증
- ArgoCD applications 검증
- Monitoring stack 검증
- **Grafana datasource 충돌 검증**
- 테스트 후 자동 cleanup

**주의**: 이 테스트는 실제 GCP 리소스를 생성하므로 비용이 발생합니다 (약 $0.5~$1 per test run).

```bash
cd test
go test -v -run TestTerraformGCPDeployment -timeout 30m
```

## 테스트 실행 순서 (권장)

### 1단계: 의존성 설치
```bash
cd test
go mod download
```

### 2단계: Basic Tests 실행
```bash
# 빠른 검증 (비용 없음)
go test -v -run TestTerraformBasicValidation -timeout 10m
go test -v -run TestTerraformOutputs -timeout 5m
```

### 3단계: Integration Tests 실행 (선택적)
```bash
# 실제 배포 테스트 (비용 발생)
# 주의: 약 20-30분 소요
go test -v -run TestTerraformGCPDeployment -timeout 30m
```

## 테스트 세부 설명

### TestTerraformBasicValidation
- Terraform init 검증
- Terraform validate 검증
- Terraform plan 생성 검증
- 실행 시간: ~2분
- 비용: 없음

### TestTerraformOutputs
- Output 변수 정의 검증
- 실행 시간: <1분
- 비용: 없음

### TestTerraformGCPDeployment (Integration Test)
전체 infrastructure lifecycle 테스트:

1. **Infrastructure 생성** (~5분)
   - VPC, Subnet, Firewall 생성
   - Compute Instances 생성 (Master + Worker)
   - Static IP 할당

2. **k3s Cluster 검증** (~5분)
   - Bootstrap script 완료 대기
   - Node 상태 확인 (Ready)
   - Kubernetes API 접근성 확인

3. **ArgoCD Applications 검증** (~5분)
   - 7개 Applications 생성 확인
   - Health status 검증 (Healthy/Progressing)

4. **Monitoring Stack 검증** (~5분)
   - 모든 pods Running 상태 확인
   - Prometheus, Grafana, Loki, Istio, Kiali 검증

5. **Grafana Datasource 검증** (중요)
   - Grafana pod restart count = 0 확인
   - Datasource 충돌 에러 없음 확인
   - Datasource sidecar ConfigMap 미생성 확인

6. **Cleanup** (~5분)
   - 모든 리소스 자동 삭제 (terraform destroy)

실행 시간: ~20-30분
비용: ~$0.5-$1

## CI/CD 통합

### GitHub Actions 예제

`.github/workflows/terratest.yml`:
```yaml
name: Terratest

on:
  pull_request:
    paths:
      - 'terraform/environments/gcp/**'
  push:
    branches:
      - main

jobs:
  terratest-basic:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'

      - name: Run Basic Tests
        working-directory: terraform/environments/gcp/test
        run: |
          go mod download
          go test -v -run TestTerraformBasicValidation -timeout 10m

  terratest-integration:
    runs-on: ubuntu-latest
    # Integration test는 main branch merge 후에만 실행
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v3

      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'

      - uses: google-github-actions/auth@v1
        with:
          credentials_json: ${{ secrets.GCP_SA_KEY }}

      - name: Run Integration Tests
        working-directory: terraform/environments/gcp/test
        run: |
          go mod download
          go test -v -run TestTerraformGCPDeployment -timeout 30m
```

## 테스트 결과 해석

### 성공 케이스
```
=== RUN   TestTerraformGCPDeployment
=== RUN   TestTerraformGCPDeployment/VerifyInfrastructure
=== RUN   TestTerraformGCPDeployment/VerifyK3sCluster
=== RUN   TestTerraformGCPDeployment/VerifyArgoCDApplications
=== RUN   TestTerraformGCPDeployment/VerifyMonitoringStack
=== RUN   TestTerraformGCPDeployment/VerifyGrafanaDatasource
    terraform_integration_test.go:XXX: ✓ Grafana datasource configuration is correct (no conflicts)
--- PASS: TestTerraformGCPDeployment (1234.56s)
PASS
```

### 실패 케이스 예제
```
--- FAIL: TestTerraformGCPDeployment/VerifyGrafanaDatasource (45.67s)
    terraform_integration_test.go:XXX: Grafana pod has restarted 3 times
    terraform_integration_test.go:XXX: Error Trace: ...
    terraform_integration_test.go:XXX: Error: Grafana should not have datasource conflict error
    terraform_integration_test.go:XXX: Messages: Found error in logs: "Only one datasource per organization can be marked as default"
```

## Troubleshooting

### 문제: "kubectl: command not found"
```bash
# macOS
brew install kubectl
```

### 문제: "kubeconfig not found"
```bash
# Master node에서 kubeconfig 가져오기
gcloud compute ssh titanium-k3s-master --zone=asia-northeast3-a --tunnel-through-iap \
  --command="sudo cat /etc/rancher/k3s/k3s.yaml" | \
  sed "s/127.0.0.1/<MASTER_IP>/g" > ~/.kube/config-gcp
```

### 문제: "timeout waiting for pods"
- Bootstrap script 실행 시간이 예상보다 길 수 있음
- Test timeout 값을 늘려보기: `-timeout 45m`

### 문제: "terraform destroy failed"
```bash
# 수동으로 cleanup
cd ../
terraform destroy -auto-approve
```

## 비용 최적화

### Integration Test 실행 빈도 제한
- PR마다 실행하지 말고, main branch merge 후에만 실행
- 또는 매일 1회 scheduled test 실행

### Spot VM 사용 (Worker Node)
현재 설정에서 worker node는 이미 spot VM을 사용하므로 비용이 저렴합니다.

### Test 환경 별도 관리
- Production 프로젝트와 분리된 test 전용 GCP 프로젝트 사용 권장

## 참고 자료

- [Terratest 공식 문서](https://terratest.gruntwork.io/)
- [Terratest GCP Examples](https://github.com/gruntwork-io/terratest/tree/master/examples)
- [Terraform Testing Best Practices](https://www.terraform.io/docs/cloud/guides/testing.html)
