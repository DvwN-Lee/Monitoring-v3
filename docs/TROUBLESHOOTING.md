# GCP Terratest Troubleshooting Guide

이 문서는 GCP 환경에서 Terratest를 사용한 Infrastructure 테스트 중 발생할 수 있는 문제와 해결 방법을 정리합니다.

---

## 목차

0. [전제 조건](#0-전제-조건)
1. [환경 설정 관련](#1-환경-설정-관련)
2. [테스트 격리 관련](#2-테스트-격리-관련)
3. [GCP 리소스 검증 관련](#3-gcp-리소스-검증-관련)
4. [멱등성 테스트 관련](#4-멱등성-테스트-관련)
5. [네트워크 테스트 관련](#5-네트워크-테스트-관련)
6. [Application 상태 검증 관련](#6-application-상태-검증-관련)
7. [Retry 메커니즘](#7-retry-메커니즘)
8. [디버깅 및 로그 수집](#8-디버깅-및-로그-수집)

---

## 0. 전제 조건

Terratest를 실행하기 전에 다음 인증 및 환경 설정이 완료되어야 합니다.

### 0.1 GCP 인증

**로컬 환경**
```bash
# gcloud CLI 인증
gcloud auth login
gcloud auth application-default login

# 프로젝트 설정
gcloud config set project <PROJECT_ID>
```

**CI/CD 환경 (Service Account)**
```bash
# Service Account Key 파일 경로 설정
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"

# 또는 Workload Identity Federation 사용 (권장)
gcloud auth login --cred-file=<CREDENTIAL_FILE>
```

**필요 IAM 권한**
- `roles/compute.admin` - VM, Network 리소스 관리
- `roles/iam.serviceAccountUser` - Service Account 사용
- `roles/storage.admin` - Terraform State Backend (GCS 사용 시)

### 0.2 Kubernetes 인증

**Kubeconfig 설정**
```bash
# GKE Cluster 인증 (GKE 사용 시)
gcloud container clusters get-credentials <CLUSTER_NAME> --zone <ZONE>

# K3s Cluster 인증 (테스트 완료 후)
export KUBECONFIG=/path/to/kubeconfig
```

### 0.3 필수 도구

| 도구 | 최소 버전 | 확인 명령어 |
|------|----------|------------|
| Go | 1.21+ | `go version` |
| Terraform | 1.5+ | `terraform version` |
| gcloud CLI | 최신 | `gcloud version` |
| kubectl | 1.28+ | `kubectl version --client` |

### 0.4 GCP API 활성화

테스트 실행 전 필요한 GCP API가 활성화되어 있어야 합니다.

```bash
# 필수 API 활성화
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com
```

### 0.5 테스트 타임아웃 설정

**중요:** Go 테스트의 기본 타임아웃(10분)은 Infrastructure 통합 테스트에 부족합니다. 반드시 `-timeout` 플래그를 사용하세요.

```bash
# 권장 타임아웃 설정
go test -v -timeout 60m ./...          # 전체 테스트
go test -v -timeout 30m -run TestPlan  # Plan 테스트만
```

**타임아웃 미설정 시 발생하는 오류:**
```
panic: test timed out after 10m0s
```

---

## 1. 환경 설정 관련

### 1.1 GCP Quota 초과 및 API 미활성화

**증상 1: Quota 초과**
```
Error: Quota 'CPUS' exceeded. Limit: 8.0 in region asia-northeast3.
```

**해결:**
- GCP Console > IAM & Admin > Quotas에서 Quota 상향 요청
- 또는 테스트에서 사용하는 VM 사양 축소

**증상 2: API 미활성화**
```
Error: Compute Engine API has not been used in project [PROJECT_ID] before
```

**해결:**
```bash
gcloud services enable compute.googleapis.com --project <PROJECT_ID>
```

**Terraform에서 자동 활성화:**
```hcl
resource "google_project_service" "compute" {
  project = var.project_id
  service = "compute.googleapis.com"
}
```

---

### 1.2 terraform.InitAndApplyE 반환값 불일치

**증상**
```
assignment mismatch: 1 variable but terraform.InitAndApplyE returns 2 values
```

**원인**
`terraform.InitAndApplyE`는 `(string, error)` 두 개의 값을 반환합니다. 첫 번째 값은 Terraform output을 포함한 문자열입니다.

**해결**
```go
// 잘못된 사용
err := terraform.InitAndApplyE(t, terraformOptions)

// 올바른 사용
_, err := terraform.InitAndApplyE(t, terraformOptions)
```

---

### 1.2 terraform.PlanExitCode 함수 존재 여부

**우려사항**
Gemini 분석에서 `terraform.PlanExitCode` 함수의 존재 여부에 대한 우려가 제기되었습니다.

**확인 방법**
```bash
go doc github.com/gruntwork-io/terratest/modules/terraform PlanExitCode
```

**확인 결과**
```
func PlanExitCode(t testing.TestingT, options *Options) int
    PlanExitCode runs terraform plan and returns the exit code.
```

**결론**
`PlanExitCode`는 Terratest 표준 함수로 정상 사용 가능합니다. Exit code 의미:
- `0`: 변경 없음 (멱등성 통과)
- `1`: 오류 발생
- `2`: 변경 있음 (멱등성 실패)

---

### 1.3 IPv6 호환성 경고

**증상**
```
./helpers.go:415:25: address format "%s:%d" does not work with IPv6
```

**원인**
`fmt.Sprintf("%s:%d", targetIP, port)` 형식은 IPv6 주소와 호환되지 않습니다.

**해결**
```go
// 잘못된 사용
address := fmt.Sprintf("%s:%d", targetIP, port)

// 올바른 사용 (net 패키지 사용)
import "net"
address := net.JoinHostPort(targetIP, fmt.Sprintf("%d", port))
```

---

## 2. 테스트 격리 관련

### 2.1 병렬 테스트 리소스 충돌

**증상**
동일한 Cluster 이름으로 인해 병렬 테스트 간 리소스 충돌이 발생합니다.

**원인**
여러 테스트가 동일한 `cluster_name`을 사용하면 GCP에서 리소스 이름 충돌이 발생합니다.

**해결**

1. **임시 디렉터리 복사**
```go
tempFolder := test_structure.CopyTerraformFolderToTemp(t, "../", ".")
```

2. **고유 Cluster 이름 생성**
```go
func GenerateUniqueClusterName(t *testing.T, prefix string) string {
    uniqueID := random.UniqueId()
    timestamp := time.Now().Format("0102-1504")
    return fmt.Sprintf("%s-%s-%s", prefix, timestamp, strings.ToLower(uniqueID))
}
```

3. **격리된 Terraform 옵션 사용**
```go
func GetIsolatedTerraformOptions(t *testing.T) *terraform.Options {
    tempFolder := test_structure.CopyTerraformFolderToTemp(t, "../", ".")
    uniqueClusterName := GenerateUniqueClusterName(t, "test")

    return &terraform.Options{
        TerraformDir: tempFolder,
        Vars: map[string]interface{}{
            "cluster_name": uniqueClusterName,
            // ... other vars
        },
    }
}
```

---

## 3. GCP 리소스 검증 관련

### 3.1 Spot Instance 검증 실패

**증상**
하드코딩된 `projectID`, `zone` 값으로 인해 다른 환경에서 테스트 실패가 발생합니다.

**기존 방식 (문제)**
```go
func VerifySpotInstance(t *testing.T, instanceName string) bool {
    projectID := "hardcoded-project-id"
    zone := "hardcoded-zone"
    // ...
}
```

**해결: 동적 파라미터 지원**
```go
// 동적 파라미터 버전
func VerifySpotInstance(t *testing.T, instanceName, projectID, zone string) bool {
    cmd := shell.Command{
        Command: "gcloud",
        Args: []string{
            "compute", "instances", "describe", instanceName,
            "--project", projectID,
            "--zone", zone,
            "--format", "json",
        },
    }
    // ...
}

// 하위 호환성 유지 버전
func VerifySpotInstanceWithDefaults(t *testing.T, instanceName string) bool {
    return VerifySpotInstance(t, instanceName, DefaultProjectID, DefaultZone)
}
```

---

### 3.2 Node Ready 상태 검증 부정확

**증상**
Node 상태를 확인할 때 `Ready` 문자열만 확인하면 `NotReady` 상태도 통과할 수 있습니다.

**기존 방식 (문제)**
```go
// status 컬럼만 확인
if strings.Contains(output, "Ready") {
    return true
}
```

**해결: 조건부 상태 확인**
```go
func VerifyNodeReady(t *testing.T, host ssh.Host, nodeName string) bool {
    cmd := fmt.Sprintf("kubectl get node %s -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'", nodeName)
    output, err := RunSSHCommand(t, host, cmd)
    if err != nil {
        return false
    }
    return strings.TrimSpace(output) == "True"
}
```

---

## 4. 멱등성 테스트 관련

### 4.1 기존 방식의 문제점

**기존 방식**
```go
// InitAndApply 2회 실행
terraform.InitAndApply(t, opts)
terraform.InitAndApply(t, opts)  // 변경 여부 판단 불가
```

**문제점**
- 두 번째 Apply가 성공해도 실제로 변경이 있었는지 명확히 판단할 수 없습니다.
- 멱등성 위반 여부를 정확히 검증할 수 없습니다.

**해결: PlanExitCode 활용**
```go
func TestIdempotency(t *testing.T) {
    opts := GetDefaultTerraformOptions(t)
    defer terraform.Destroy(t, opts)  // 중요: InitAndApply 전에 선언

    // 1차 배포
    terraform.InitAndApply(t, opts)

    // 멱등성 검증: Plan 결과 확인
    exitCode := terraform.PlanExitCode(t, opts)

    switch exitCode {
    case 0:
        t.Log("멱등성 검증 통과: 변경 사항 없음")
    case 2:
        t.Error("멱등성 검증 실패: 재적용 시 변경이 발생함")
    default:
        t.Errorf("Plan 실행 오류: exit code %d", exitCode)
    }
}
```

### 4.2 defer terraform.Destroy 배치 순서

**중요:** `defer terraform.Destroy`는 반드시 `terraform.InitAndApply` **이전**에 선언해야 합니다.

**잘못된 배치 (리소스 누수 발생)**
```go
func TestBad(t *testing.T) {
    opts := GetDefaultTerraformOptions(t)

    // InitAndApply가 panic 발생 시 Destroy가 호출되지 않음
    terraform.InitAndApply(t, opts)
    defer terraform.Destroy(t, opts)  // 위험: 늦은 선언
}
```

**올바른 배치**
```go
func TestGood(t *testing.T) {
    opts := GetDefaultTerraformOptions(t)
    defer terraform.Destroy(t, opts)  // InitAndApply 전에 선언

    // InitAndApply가 실패해도 Destroy가 실행됨
    terraform.InitAndApply(t, opts)
}
```

**원리:** Go의 `defer`는 선언 시점에 등록되므로, `InitAndApply`가 `panic`을 발생시켜도 이미 등록된 `defer`는 실행됩니다.

---

## 5. 네트워크 테스트 관련

### 5.1 Firewall Source Ranges 검증

**목적**
SSH Firewall이 전체 인터넷(0.0.0.0/0)이 아닌 IAP 범위(35.235.240.0/20)만 허용하는지 확인합니다.

**검증 방법**
```go
func VerifyFirewallSourceRanges(t *testing.T, projectID, firewallName string, expectedRanges []string) error {
    output, err := runGcloudCommand(t,
        "compute", "firewall-rules", "describe", firewallName,
        "--project", projectID,
        "--format", "json",
    )
    if err != nil {
        return err
    }

    var firewall GCPFirewallRule
    json.Unmarshal([]byte(output), &firewall)

    for _, expected := range expectedRanges {
        found := false
        for _, actual := range firewall.SourceRanges {
            if actual == expected {
                found = true
                break
            }
        }
        if !found {
            return fmt.Errorf("expected source range %s not found", expected)
        }
    }
    return nil
}
```

---

### 5.2 차단 포트 연결 테스트

**목적**
외부에서 접근하면 안 되는 포트(8080, 9090, 2379, 3306, 5432, 10250 등)가 실제로 차단되었는지 확인합니다.

**검증 방법**
```go
var BlockedPorts = []int{8080, 9090, 2379, 2380, 3306, 5432, 10250, 10251, 10252}

func TestPortBlocked(t *testing.T, targetIP string, port int, timeout time.Duration) bool {
    address := net.JoinHostPort(targetIP, fmt.Sprintf("%d", port))
    conn, err := net.DialTimeout("tcp", address, timeout)
    if err != nil {
        // 연결 실패 = 포트 차단됨
        return true
    }
    conn.Close()
    // 연결 성공 = 포트 열림 (차단 실패)
    return false
}
```

---

## 6. Application 상태 검증 관련

### 6.1 ArgoCD Application 상태 검증

**목적**
ArgoCD Application이 `Synced` + `Healthy` 상태인지 확인합니다.

**검증 방법**
```go
type ArgoAppStatus struct {
    Name         string `json:"name"`
    SyncStatus   string `json:"syncStatus"`
    HealthStatus string `json:"healthStatus"`
}

func GetArgoCDApplicationStatuses(t *testing.T, host ssh.Host) ([]ArgoAppStatus, error) {
    cmd := `kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name},{.status.sync.status},{.status.health.status}{"\n"}{end}'`
    output, err := RunSSHCommand(t, host, cmd)
    if err != nil {
        return nil, err
    }

    var statuses []ArgoAppStatus
    lines := strings.Split(strings.TrimSpace(output), "\n")
    for _, line := range lines {
        parts := strings.Split(line, ",")
        if len(parts) >= 3 {
            statuses = append(statuses, ArgoAppStatus{
                Name:         parts[0],
                SyncStatus:   parts[1],
                HealthStatus: parts[2],
            })
        }
    }
    return statuses, nil
}
```

---

### 6.2 Prometheus Target Scraping 검증

**목적**
Prometheus가 실제로 메트릭을 수집하고 있는지 확인합니다.

**검증 방법**
```go
type PrometheusTarget struct {
    Labels    map[string]string `json:"labels"`
    ScrapeURL string            `json:"scrapeUrl"`
    Health    string            `json:"health"`
    LastError string            `json:"lastError"`
}

func GetPrometheusTargets(t *testing.T, host ssh.Host, port string) ([]PrometheusTarget, error) {
    cmd := fmt.Sprintf("curl -s http://localhost:%s/api/v1/targets", port)
    output, err := RunSSHCommand(t, host, cmd)
    if err != nil {
        return nil, err
    }

    var response struct {
        Status string `json:"status"`
        Data   struct {
            ActiveTargets []PrometheusTarget `json:"activeTargets"`
        } `json:"data"`
    }

    json.Unmarshal([]byte(output), &response)
    return response.Data.ActiveTargets, nil
}

func VerifyPrometheusTargetsUp(t *testing.T, host ssh.Host, requiredJobs []string) error {
    targets, err := GetPrometheusTargets(t, host, "9090")
    if err != nil {
        return err
    }

    for _, job := range requiredJobs {
        found := false
        for _, target := range targets {
            if target.Labels["job"] == job && target.Health == "up" {
                found = true
                break
            }
        }
        if !found {
            return fmt.Errorf("prometheus job '%s' not found or not healthy", job)
        }
    }
    return nil
}
```

---

## 7. Retry 메커니즘

Cloud Infrastructure 테스트는 네트워크 지연이나 API 일시적 오류로 인한 Flakiness(불안정성)가 빈번합니다. Retry 메커니즘을 적용하여 안정성을 높일 수 있습니다.

### 7.1 Terraform Options Retry 설정

**Terraform Apply/Destroy 재시도**
```go
terraformOptions := &terraform.Options{
    TerraformDir: "../",
    Vars: map[string]interface{}{
        "cluster_name": clusterName,
    },
    // Retry 설정
    MaxRetries:         3,
    TimeBetweenRetries: 10 * time.Second,
    RetryableTerraformErrors: map[string]string{
        ".*Error creating.*":          "GCP API 일시적 오류",
        ".*timeout while waiting.*":   "리소스 생성 타임아웃",
        ".*connection reset by peer.*": "네트워크 연결 오류",
        ".*rate limit.*":              "API Rate Limit",
    },
}
```

### 7.2 Terratest retry 패키지 활용

**검증 로직 재시도**
```go
import "github.com/gruntwork-io/terratest/modules/retry"

func TestWithRetry(t *testing.T) {
    maxRetries := 10
    sleepBetweenRetries := 10 * time.Second

    retry.DoWithRetry(t, "K3s Node Ready 대기", maxRetries, sleepBetweenRetries, func() (string, error) {
        output, err := RunSSHCommand(t, host, "kubectl get nodes")
        if err != nil {
            return "", err
        }
        if !strings.Contains(output, "Ready") {
            return "", fmt.Errorf("Node가 아직 Ready 상태가 아님")
        }
        return output, nil
    })
}
```

### 7.3 HTTP Endpoint 재시도

**서비스 가용성 대기**
```go
import "github.com/gruntwork-io/terratest/modules/http-helper"

func WaitForService(t *testing.T, url string) {
    maxRetries := 30
    sleepBetweenRetries := 10 * time.Second

    http_helper.HttpGetWithRetry(
        t,
        url,
        nil,                    // TLS config
        200,                    // Expected status code
        "",                     // Expected body (빈 문자열이면 무시)
        maxRetries,
        sleepBetweenRetries,
    )
}
```

### 7.4 일반적인 재시도 대상

| 상황 | 권장 재시도 횟수 | 대기 시간 |
|------|-----------------|----------|
| GCP API 호출 | 3회 | 10초 |
| K3s Node Ready | 30회 | 10초 (총 5분) |
| Pod Ready | 60회 | 5초 (총 5분) |
| HTTP Endpoint | 30회 | 10초 (총 5분) |
| ArgoCD Sync | 60회 | 10초 (총 10분) |

---

## 8. 디버깅 및 로그 수집

테스트 실패 시 원인 분석을 위한 디버깅 방법입니다.

### 8.1 테스트 Stage 건너뛰기

`test_structure` 패키지를 사용하면 특정 Stage를 건너뛰고 인프라를 유지할 수 있습니다.

**Stage 기반 테스트 구조**
```go
import "github.com/gruntwork-io/terratest/modules/test-structure"

func TestInfrastructure(t *testing.T) {
    workingDir := "../"

    // Stage: Setup
    defer test_structure.RunTestStage(t, "teardown", func() {
        terraformOptions := test_structure.LoadTerraformOptions(t, workingDir)
        terraform.Destroy(t, terraformOptions)
    })

    test_structure.RunTestStage(t, "setup", func() {
        terraformOptions := GetDefaultTerraformOptions(t)
        test_structure.SaveTerraformOptions(t, workingDir, terraformOptions)
        terraform.InitAndApply(t, terraformOptions)
    })

    // Stage: Validate
    test_structure.RunTestStage(t, "validate", func() {
        terraformOptions := test_structure.LoadTerraformOptions(t, workingDir)
        // 검증 로직
    })
}
```

**Teardown 건너뛰기 (디버깅용)**
```bash
# teardown Stage 건너뛰고 인프라 유지
SKIP_teardown=true go test -v -run TestInfrastructure

# setup도 건너뛰기 (이미 인프라가 있는 경우)
SKIP_setup=true SKIP_teardown=true go test -v -run TestInfrastructure
```

### 8.2 테스트 로그 상세 출력

**Verbose 모드 실행**
```bash
# 상세 로그 출력
go test -v -timeout 60m ./...

# 특정 테스트만 실행
go test -v -run TestNetworkLayer -timeout 30m
```

**Terraform 로그 활성화**
```bash
# Terraform 디버그 로그
export TF_LOG=DEBUG
export TF_LOG_PATH=/tmp/terraform.log

go test -v -run TestPlanResourceCount
```

### 8.3 SSH 디버깅

**테스트 중 SSH 접속 정보 출력**
```go
func TestWithSSHDebug(t *testing.T) {
    // ... terraform apply 후

    masterIP := terraform.Output(t, terraformOptions, "master_external_ip")

    t.Logf("=== SSH 디버깅 정보 ===")
    t.Logf("Master IP: %s", masterIP)
    t.Logf("SSH 명령어: ssh -i ~/.ssh/gcp_key username@%s", masterIP)
    t.Logf("Kubeconfig 복사: scp username@%s:~/.kube/config ./kubeconfig", masterIP)

    // 테스트 실패 시 여기서 멈추고 수동 디버깅 가능
    if os.Getenv("PAUSE_FOR_DEBUG") == "true" {
        t.Log("PAUSE_FOR_DEBUG=true 설정됨. 계속하려면 Enter를 누르세요...")
        fmt.Scanln()
    }
}
```

### 8.4 실패한 리소스 상태 덤프

**테스트 실패 시 상태 저장**
```go
func dumpResourceState(t *testing.T, host ssh.Host) {
    commands := []struct {
        name string
        cmd  string
    }{
        {"nodes", "kubectl get nodes -o wide"},
        {"pods", "kubectl get pods -A"},
        {"events", "kubectl get events -A --sort-by='.lastTimestamp'"},
        {"services", "kubectl get svc -A"},
        {"argocd-apps", "kubectl get applications -n argocd -o wide"},
    }

    t.Log("=== 리소스 상태 덤프 ===")
    for _, c := range commands {
        output, err := RunSSHCommand(t, host, c.cmd)
        if err != nil {
            t.Logf("[%s] 오류: %v", c.name, err)
        } else {
            t.Logf("[%s]\n%s", c.name, output)
        }
    }
}

// 테스트에서 사용
func TestWithDump(t *testing.T) {
    defer func() {
        if t.Failed() {
            dumpResourceState(t, host)
        }
    }()

    // 테스트 로직
}
```

### 8.5 CI/CD 환경 디버깅

**GitHub Actions Artifact 저장**
```yaml
- name: Run Terratest
  run: go test -v -timeout 60m ./... 2>&1 | tee test-output.log
  continue-on-error: true

- name: Upload Test Logs
  if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: terratest-logs
    path: |
      test-output.log
      /tmp/terraform.log
```

---

## 테스트 계층별 비용 및 실행 시간

| Layer | 테스트 범위 | 예상 비용 | 실행 시간 |
|-------|-------------|----------|----------|
| Layer 1 (Plan) | terraform plan 분석 | 무료 | 2분 미만 |
| Layer 2 (Network) | VPC, Subnet, Firewall | 낮음 | 5분 미만 |
| Layer 3 (Compute) | VM Instance, K3s | 중간 | 15분 |
| Layer 4 (Integration) | 전체 Stack 통합 | 높음 | 30분 이상 |

---

## 관련 파일

- `terraform/environments/gcp/test/helpers.go` - 공통 Helper 함수
- `terraform/environments/gcp/test/10_plan_unit_test.go` - Plan Layer 테스트
- `terraform/environments/gcp/test/20_network_layer_test.go` - Network Layer 테스트
- `terraform/environments/gcp/test/30_compute_k3s_test.go` - Compute Layer 테스트
- `terraform/environments/gcp/test/40_full_integration_test.go` - Integration Layer 테스트
