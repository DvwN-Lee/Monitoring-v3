# Testing Troubleshooting

Terratest 및 테스트 자동화 관련 문제.

---

## 11. JSON 파싱 에러

### 문제

```
Error: json: cannot unmarshal string into Go struct field .disks.diskSizeGb of type int64
Test: TestComputeAndK3s/MasterInstanceSpec
```

### 원인

gcloud 명령어에서 반환하는 `diskSizeGb` 값이 문자열이지만, Go 구조체에서 `int64`로 정의되어 JSON 파싱이 실패.

### 해결

**파일**: `test/30_compute_k3s_test.go`

```go
// Before
type GCPInstance struct {
    Disks []struct {
        DiskSizeGb int64 `json:"diskSizeGb"`
    } `json:"disks"`
}

// After
type GCPInstance struct {
    Disks []struct {
        DiskSizeGb string `json:"diskSizeGb"`
    } `json:"disks"`
}
```

---

## 12. SSH 키 경로 문제

### 문제 1: Tilde 확장 실패

```
Error: Invalid function argument
Invalid value for "path" parameter: no file exists at "~/.ssh/id_rsa.pub"
```

### 원인

Terraform의 `file()` 함수는 tilde (`~`) 확장을 지원하지 않는다.

### 해결

**파일**: `terraform/environments/gcp/main.tf`

```hcl
metadata = {
  ssh-keys = "ubuntu:${file(pathexpand(var.ssh_public_key_path))}"
}
```

### 문제 2: 테스트에서 잘못된 SSH 키 경로

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

이전 테스트에서 생성한 Service Account가 정리되지 않고 잔존.

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

`test-ssh.auto.tfvars` 파일이 이전 테스트에서 생성되어 잔존.

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
go test -v -run "TestFullIntegration" -timeout 45m
```

---

## 17. 리소스 정리 실패

### 문제

테스트 실패 후 GCP 리소스가 잔존.

### 확인

```bash
gcloud compute instances list --filter="name~^tt-" --project=PROJECT_ID
gcloud compute networks list --filter="name~^tt-" --project=PROJECT_ID
```

### 정리

```bash
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

MIG Auto-healing으로 Worker VM이 재생성될 때, 동일한 hostname으로 K3s에 Join을 시도하면 password 불일치로 거부.

### 해결

**파일**: `terraform/environments/gcp/scripts/k3s-agent.sh`

```bash
curl -sfL https://get.k3s.io | K3S_URL="https://${master_ip}:6443" K3S_TOKEN="${k3s_token}" sh -s - --with-node-id
```
