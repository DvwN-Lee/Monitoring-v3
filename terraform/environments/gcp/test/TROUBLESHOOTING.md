# Terratest Troubleshooting Guide

Terratest 실행 중 발생할 수 있는 문제와 해결 방법을 정리한 문서입니다.

## 목차

1. [JSON 파싱 에러](#1-json-파싱-에러)
2. [SSH 키 경로 문제](#2-ssh-키-경로-문제)
3. [Service Account 충돌](#3-service-account-충돌)
4. [Firewall Source Ranges 테스트 실패](#4-firewall-source-ranges-테스트-실패)
5. [Network Layer 테스트 문제](#5-network-layer-테스트-문제)
6. [테스트 Timeout](#6-테스트-timeout)
7. [리소스 정리 실패](#7-리소스-정리-실패)

---

## 1. JSON 파싱 에러

### 문제
```
Error: json: cannot unmarshal string into Go struct field .disks.diskSizeGb of type int64
Test: TestComputeAndK3s/MasterInstanceSpec
Messages: Instance JSON 파싱 실패
```

### 원인
gcloud 명령어에서 반환하는 `diskSizeGb` 값이 문자열이지만, Go 구조체에서 `int64`로 정의되어 JSON 파싱이 실패합니다.

### 해결 방법

**파일**: `test/30_compute_k3s_test.go`

```go
// Before (문제 코드)
type GCPInstance struct {
    Disks []struct {
        Boot       bool  `json:"boot"`
        DiskSizeGb int64 `json:"diskSizeGb"`  // ❌ int64로 정의
    } `json:"disks"`
}

// After (수정 코드)
type GCPInstance struct {
    Disks []struct {
        Boot       bool   `json:"boot"`
        DiskSizeGb string `json:"diskSizeGb"`  // ✓ string으로 변경
    } `json:"disks"`
}

// testInstanceSpec 함수에서 문자열을 정수로 변환
for _, disk := range instance.Disks {
    if disk.Boot {
        var diskSize int64
        fmt.Sscanf(disk.DiskSizeGb, "%d", &diskSize)
        assert.GreaterOrEqual(t, diskSize, int64(expectedDiskSize))
    }
}
```

### 검증
```bash
go test -v -run "TestComputeAndK3s" -timeout 30m
```

**성공 로그**:
```
--- PASS: TestComputeAndK3s/MasterInstanceSpec (1.21s)
--- PASS: TestComputeAndK3s/WorkerInstanceSpec (0.64s)
```

---

## 2. SSH 키 경로 문제

### 문제 1: Tilde (~) 확장 실패

```
Error: Invalid function argument
  on main.tf line 159
Invalid value for "path" parameter: no file exists at "~/.ssh/id_rsa.pub"
```

### 원인
Terraform의 `file()` 함수는 tilde (`~`) 확장을 지원하지 않습니다.

### 해결 방법

**파일**: `terraform/environments/gcp/main.tf`

```hcl
# Before (문제 코드)
metadata = {
  ssh-keys = "ubuntu:${file(var.ssh_public_key_path)}"  # ❌ ~/ 확장 안됨
}

# After (수정 코드)
metadata = {
  ssh-keys = "ubuntu:${file(pathexpand(var.ssh_public_key_path))}"  # ✓ pathexpand() 사용
}
```

**적용 위치**:
- `google_compute_instance.k3s_master` (line 159)
- `google_compute_instance.k3s_worker` (line 212)

---

### 문제 2: 테스트에서 잘못된 SSH 키 경로 사용

```
Error: Invalid function argument
Invalid value for "path" parameter: no file exists at "/Users/idongju/.ssh/id_rsa.pub"
```

### 원인
`GetTestTerraformVars()` 함수에서 `ssh_public_key_path`를 설정하지 않아, `variables.tf`의 기본값 (`~/.ssh/id_rsa.pub`)이 사용되었지만 실제 키는 `titanium-key.pub`입니다.

### 해결 방법

**파일**: `test/helpers.go`

```go
// Before (문제 코드)
func GetTestTerraformVars() map[string]interface{} {
    return map[string]interface{}{
        "project_id":             DefaultProjectID,
        // ... 다른 변수들
        // ssh_public_key_path가 누락됨 ❌
    }
}

// After (수정 코드)
func GetTestTerraformVars() map[string]interface{} {
    homeDir, _ := os.UserHomeDir()
    return map[string]interface{}{
        "project_id":             DefaultProjectID,
        // ... 다른 변수들
        "ssh_public_key_path":    filepath.Join(homeDir, ".ssh", "titanium-key.pub"),  // ✓ 추가
    }
}
```

---

## 3. Service Account 충돌

### 문제
```
Error: Error creating service account: googleapi: Error 409:
Service account terratest-k3s-sa already exists within project
```

### 원인
이전 Full Integration 테스트에서 생성한 Service Account가 정리되지 않고 남아있습니다.

### 해결 방법

**1. Service Account 확인**:
```bash
gcloud iam service-accounts list \
  --project=titanium-k3s-1765951764 \
  --filter="email:terratest-k3s-sa@*"
```

**2. Service Account 삭제**:
```bash
gcloud iam service-accounts delete \
  terratest-k3s-sa@titanium-k3s-1765951764.iam.gserviceaccount.com \
  --project=titanium-k3s-1765951764 \
  --quiet
```

**3. 테스트 재실행**:
```bash
go test -v -run "TestFullIntegration" -timeout 45m
```

### 예방 방법
- `GetIsolatedTerraformOptions()` 사용 시 Service Account 이름도 랜덤화됨
- Full Integration 테스트는 `GetDefaultTerraformOptions()` 사용하여 고정 이름 사용
- 테스트 실패 시 `defer terraform.Destroy()`가 실행되지 않을 수 있음

---

## 4. Firewall Source Ranges 테스트 실패

### 문제
```
--- FAIL: TestPlanFirewallSourceRanges (2.34s)
    Expected SSH firewall to have only IAP range (35.235.240.0/20)
    but found: [35.235.240.0/20, 14.35.115.201/32]
```

### 원인
`test-ssh.auto.tfvars` 파일이 이전 테스트에서 생성되어 남아있어, 테스트 환경 IP가 추가로 포함되었습니다.

### 해결 방법

**1. tfvars 파일 삭제**:
```bash
cd /Users/idongju/Desktop/Git/Monitoring-v3/terraform/environments/gcp
rm -f test-ssh.auto.tfvars
```

**2. 테스트 재실행**:
```bash
cd test
go test -v -run "TestPlanFirewallSourceRanges" -timeout 5m
```

### 예방 방법
- `.gitignore`에 `test-ssh.auto.tfvars` 추가
- 테스트 후 자동 cleanup 로직 추가

**`.gitignore`**:
```
test-ssh.auto.tfvars
*.auto.tfvars
```

---

## 5. Network Layer 테스트 문제

### 문제 1: VPC 이미 존재

```
Error: Error creating network: googleapi: Error 409:
The resource 'projects/.../global/networks/terratest-k3s-vpc' already exists
```

### 해결 방법
```bash
# VPC 삭제
gcloud compute networks delete terratest-k3s-vpc \
  --project=titanium-k3s-1765951764 \
  --quiet
```

---

### 문제 2: Firewall 이름 구성 오류

```
Error: 404 Not Found
Firewall rule 'terratest-k3s-vpc-allow-ssh' not found
```

### 원인
VPC 이름 (`terratest-k3s-vpc`)을 사용하여 Firewall 이름을 구성했지만, 실제로는 클러스터 이름 (`terratest-k3s`)을 사용해야 합니다.

### 해결 방법

**파일**: `test/20_network_layer_test.go`

```go
// Before (문제 코드)
func testFirewallRule(t *testing.T, vpcName string, ruleSuffix string, expectedPort string) {
    firewallName := fmt.Sprintf("%s-%s", vpcName, ruleSuffix)  // ❌ vpcName 사용
}

// After (수정 코드)
func testFirewallRule(t *testing.T, vpcName string, ruleSuffix string, expectedPort string) {
    // VPC 이름에서 "-vpc" 제거하여 cluster_name 추출
    clusterName := strings.TrimSuffix(vpcName, "-vpc")  // ✓ 수정
    firewallName := fmt.Sprintf("%s-%s", clusterName, ruleSuffix)
}
```

---

## 6. 테스트 Timeout

### 문제
```
panic: test timed out after 30m0s
```

### 원인
- K3s 클러스터 부팅 시간이 예상보다 김
- 네트워크 지연
- ArgoCD Application Sync 시간 소요

### 해결 방법

**1. Timeout 값 증가**:
```bash
# 기본 30분 → 45분으로 증가
go test -v -run "TestFullIntegration" -timeout 45m
```

**2. 개별 테스트 Timeout 조정**:

**파일**: `test/*_test.go`

```go
// Retry 설정 조정
maxRetries := 60
sleepBetweenRetries := 10 * time.Second  // 총 10분 대기
```

---

## 7. 리소스 정리 실패

### 문제
테스트 실패 후 GCP 리소스가 남아있음

### 확인 방법
```bash
# Compute Instances 확인
gcloud compute instances list --filter="name~^tt-" --project=titanium-k3s-1765951764

# Networks 확인
gcloud compute networks list --filter="name~^tt-" --project=titanium-k3s-1765951764

# Service Accounts 확인
gcloud iam service-accounts list --filter="email~^tt-" --project=titanium-k3s-1765951764
```

### 수동 정리 방법

**1. Terraform으로 정리**:
```bash
cd /Users/idongju/Desktop/Git/Monitoring-v3/terraform/environments/gcp
terraform destroy -auto-approve
```

**2. gcloud로 직접 삭제**:
```bash
# Instance 삭제
gcloud compute instances delete INSTANCE_NAME \
  --zone=asia-northeast3-a \
  --project=titanium-k3s-1765951764 \
  --quiet

# Firewall 삭제
gcloud compute firewall-rules delete FIREWALL_NAME \
  --project=titanium-k3s-1765951764 \
  --quiet

# Network 삭제 (Subnet 먼저 삭제 필요)
gcloud compute networks subnets delete SUBNET_NAME \
  --region=asia-northeast3 \
  --project=titanium-k3s-1765951764 \
  --quiet

gcloud compute networks delete NETWORK_NAME \
  --project=titanium-k3s-1765951764 \
  --quiet
```

**3. 스크립트로 일괄 정리**:
```bash
#!/bin/bash
# cleanup-test-resources.sh

PROJECT_ID="titanium-k3s-1765951764"
ZONE="asia-northeast3-a"
REGION="asia-northeast3"

# Instances
gcloud compute instances list --filter="name~^tt-" --project=$PROJECT_ID --format="value(name)" | \
xargs -I {} gcloud compute instances delete {} --zone=$ZONE --project=$PROJECT_ID --quiet

# Firewall rules
gcloud compute firewall-rules list --filter="name~^tt-" --project=$PROJECT_ID --format="value(name)" | \
xargs -I {} gcloud compute firewall-rules delete {} --project=$PROJECT_ID --quiet

# Subnets
gcloud compute networks subnets list --filter="name~^tt-" --project=$PROJECT_ID --format="value(name)" | \
xargs -I {} gcloud compute networks subnets delete {} --region=$REGION --project=$PROJECT_ID --quiet

# Networks
gcloud compute networks list --filter="name~^tt-" --project=$PROJECT_ID --format="value(name)" | \
xargs -I {} gcloud compute networks delete {} --project=$PROJECT_ID --quiet

# Service Accounts
gcloud iam service-accounts list --filter="email~^tt-" --project=$PROJECT_ID --format="value(email)" | \
xargs -I {} gcloud iam service-accounts delete {} --project=$PROJECT_ID --quiet

echo "Cleanup complete!"
```

---

## 일반적인 디버깅 팁

### 1. 로그 확인
```bash
# 테스트 로그
tail -100 /tmp/phase*-test.log

# Terraform 로그
export TF_LOG=DEBUG
go test -v -run "TestComputeAndK3s" -timeout 30m
```

### 2. 특정 테스트만 실행
```bash
# 서브 테스트 지정
go test -v -run "TestComputeAndK3s/MasterInstanceSpec" -timeout 10m

# 여러 패턴 매칭
go test -v -run "TestPlan.*Config" -timeout 5m
```

### 3. 병렬 실행 비활성화
```bash
# 디버깅 시 순차 실행
go test -v -run "TestCompute" -timeout 30m -parallel 1
```

### 4. Verbose 출력
```bash
# 상세 로그 출력
go test -v -run "TestComputeIdempotency" -timeout 30m 2>&1 | tee test.log
```

---

## 추가 도움말

### GCP Console에서 확인
1. [Compute Engine Instances](https://console.cloud.google.com/compute/instances?project=titanium-k3s-1765951764)
2. [VPC Networks](https://console.cloud.google.com/networking/networks/list?project=titanium-k3s-1765951764)
3. [Firewall Rules](https://console.cloud.google.com/networking/firewalls/list?project=titanium-k3s-1765951764)
4. [Service Accounts](https://console.cloud.google.com/iam-admin/serviceaccounts?project=titanium-k3s-1765951764)

### 유용한 명령어
```bash
# 테스트 중인 리소스 실시간 모니터링
watch -n 5 'gcloud compute instances list --filter="name~^tt-" --project=titanium-k3s-1765951764'

# 비용 추적
gcloud billing accounts list
```

---

## 문의 및 지원

문제가 해결되지 않으면 다음 정보를 포함하여 이슈를 생성해주세요:

1. **에러 메시지**: 전체 스택 트레이스
2. **테스트 명령어**: 실행한 정확한 명령어
3. **환경 정보**:
   ```bash
   go version
   terraform version
   gcloud version
   ```
4. **로그 파일**: `/tmp/phase*-test.log`
