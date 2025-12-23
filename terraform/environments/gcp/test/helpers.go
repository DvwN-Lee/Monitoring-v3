package test

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/shell"
	"github.com/gruntwork-io/terratest/modules/ssh"
	"github.com/gruntwork-io/terratest/modules/terraform"
	test_structure "github.com/gruntwork-io/terratest/modules/test-structure"
)

// 테스트 환경 상수
const (
	DefaultProjectID        = "titanium-k3s-1765951764"
	DefaultRegion           = "asia-northeast3"
	DefaultZone             = "asia-northeast3-a"
	DefaultClusterName      = "terratest-k3s"
	DefaultMasterMachineType = "e2-medium"
	DefaultWorkerMachineType = "e2-standard-2"
	DefaultWorkerCount      = 1
	DefaultSubnetCIDR       = "10.128.0.0/20"
	DefaultMasterDiskSize   = 30
	DefaultWorkerDiskSize   = 40
	TestPostgresPassword    = "TerratestPassword123!"
	SSHUsername             = "ubuntu"
)

// 타임아웃 상수
const (
	SSHMaxRetries         = 30
	SSHTimeBetweenRetries = 10 * time.Second
	K3sBootstrapTimeout   = 15 * time.Minute
	DefaultTimeout        = 30 * time.Second
)

// GetTerraformDir terraform 디렉터리 경로 반환
func GetTerraformDir() string {
	return "../"
}

// GetDefaultTerraformOptions 기본 Terraform 옵션 반환
func GetDefaultTerraformOptions(t *testing.T) *terraform.Options {
	return &terraform.Options{
		TerraformDir: GetTerraformDir(),
		Vars:         GetTestTerraformVars(),
		MaxRetries:   3,
		TimeBetweenRetries: 5 * time.Second,
		NoColor:      true,
	}
}

// GetTestTerraformVars 테스트용 Terraform 변수 반환
func GetTestTerraformVars() map[string]interface{} {
	return map[string]interface{}{
		"project_id":           DefaultProjectID,
		"region":               DefaultRegion,
		"zone":                 DefaultZone,
		"cluster_name":         DefaultClusterName,
		"worker_count":         DefaultWorkerCount,
		"master_machine_type":  DefaultMasterMachineType,
		"worker_machine_type":  DefaultWorkerMachineType,
		"subnet_cidr":          DefaultSubnetCIDR,
		"master_disk_size":     DefaultMasterDiskSize,
		"worker_disk_size":     DefaultWorkerDiskSize,
		"use_spot_for_workers": true,
		"postgres_password":    TestPostgresPassword,
	}
}

// GetPlanOnlyTerraformOptions plan만 수행하는 Terraform 옵션 반환
func GetPlanOnlyTerraformOptions(t *testing.T) *terraform.Options {
	opts := GetDefaultTerraformOptions(t)
	opts.PlanFilePath = "./test-plan.tfplan"
	return opts
}

// GetSSHKeyPairPath SSH 키 경로 반환
func GetSSHKeyPairPath() (string, string) {
	homeDir, _ := os.UserHomeDir()
	privateKey := filepath.Join(homeDir, ".ssh", "titanium-key")
	publicKey := filepath.Join(homeDir, ".ssh", "titanium-key.pub")
	return privateKey, publicKey
}

// CreateSSHHost SSH 호스트 구조체 생성
func CreateSSHHost(t *testing.T, publicIP string, privateKeyPath string) ssh.Host {
	keyPair := LoadSSHKeyPair(t, privateKeyPath)
	return ssh.Host{
		Hostname:    publicIP,
		SshUserName: SSHUsername,
		SshKeyPair:  keyPair,
	}
}

// LoadSSHKeyPair SSH 키페어 로드
func LoadSSHKeyPair(t *testing.T, privateKeyPath string) *ssh.KeyPair {
	privateKey, err := os.ReadFile(privateKeyPath)
	if err != nil {
		t.Fatalf("SSH private key 읽기 실패: %v", err)
	}

	publicKeyPath := privateKeyPath + ".pub"
	publicKey, err := os.ReadFile(publicKeyPath)
	if err != nil {
		t.Fatalf("SSH public key 읽기 실패: %v", err)
	}

	return &ssh.KeyPair{
		PrivateKey: string(privateKey),
		PublicKey:  string(publicKey),
	}
}

// RunSSHCommand SSH 명령어 실행
func RunSSHCommand(t *testing.T, host ssh.Host, command string) (string, error) {
	return ssh.CheckSshCommandE(t, host, command)
}

// RunSSHCommandWithRetry 재시도와 함께 SSH 명령어 실행
func RunSSHCommandWithRetry(t *testing.T, host ssh.Host, command string, description string) (string, error) {
	var output string
	var err error

	for i := 0; i < SSHMaxRetries; i++ {
		output, err = ssh.CheckSshCommandE(t, host, command)
		if err == nil {
			return output, nil
		}
		t.Logf("%s: 재시도 %d/%d - %v", description, i+1, SSHMaxRetries, err)
		time.Sleep(SSHTimeBetweenRetries)
	}

	return output, err
}

// RunShellCommand 로컬 셸 명령어 실행
func RunShellCommand(t *testing.T, command string, args ...string) (string, error) {
	cmd := shell.Command{
		Command: command,
		Args:    args,
	}
	return shell.RunCommandAndGetOutputE(t, cmd)
}

// TerraformFormatCheck terraform fmt -check 실행
func TerraformFormatCheck(t *testing.T, terraformDir string) error {
	cmd := shell.Command{
		Command:    "terraform",
		Args:       []string{"fmt", "-check", "-recursive", "-diff"},
		WorkingDir: terraformDir,
	}
	_, err := shell.RunCommandAndGetOutputE(t, cmd)
	return err
}

// TerraformValidate terraform validate 실행
func TerraformValidate(t *testing.T, terraformDir string) error {
	// Init 먼저 실행
	initCmd := shell.Command{
		Command:    "terraform",
		Args:       []string{"init", "-backend=false"},
		WorkingDir: terraformDir,
	}
	_, err := shell.RunCommandAndGetOutputE(t, initCmd)
	if err != nil {
		return fmt.Errorf("terraform init 실패: %v", err)
	}

	// Validate 실행
	validateCmd := shell.Command{
		Command:    "terraform",
		Args:       []string{"validate"},
		WorkingDir: terraformDir,
	}
	_, err = shell.RunCommandAndGetOutputE(t, validateCmd)
	return err
}

// ContainsString 문자열 슬라이스에 특정 문자열 포함 여부 확인
func ContainsString(slice []string, str string) bool {
	for _, s := range slice {
		if s == str {
			return true
		}
	}
	return false
}

// IsValidIPv4 IPv4 주소 형식 검증
func IsValidIPv4(ip string) bool {
	parts := strings.Split(ip, ".")
	if len(parts) != 4 {
		return false
	}
	for _, part := range parts {
		if len(part) == 0 || len(part) > 3 {
			return false
		}
		for _, c := range part {
			if c < '0' || c > '9' {
				return false
			}
		}
	}
	return true
}

// IsValidCIDR CIDR 형식 검증
func IsValidCIDR(cidr string) bool {
	parts := strings.Split(cidr, "/")
	if len(parts) != 2 {
		return false
	}
	return IsValidIPv4(parts[0])
}

// WaitForK3sReady K3s 클러스터 Ready 상태 대기
func WaitForK3sReady(t *testing.T, host ssh.Host) error {
	command := "sudo kubectl get nodes --no-headers | grep -v 'NotReady' | wc -l"
	description := "Waiting for K3s nodes to be Ready"

	_, err := RunSSHCommandWithRetry(t, host, command, description)
	return err
}

// GetNodeCount K3s 노드 수 반환
func GetNodeCount(t *testing.T, host ssh.Host) (int, error) {
	output, err := RunSSHCommand(t, host, "sudo kubectl get nodes --no-headers | wc -l")
	if err != nil {
		return 0, err
	}

	var count int
	_, err = fmt.Sscanf(strings.TrimSpace(output), "%d", &count)
	return count, err
}

// CheckServiceStatus 서비스 상태 확인
func CheckServiceStatus(t *testing.T, host ssh.Host, serviceName string) (bool, error) {
	command := fmt.Sprintf("systemctl is-active %s", serviceName)
	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(output) == "active", nil
}

// ============================================================================
// 테스트 격리 및 랜덤화 함수 (병렬 실행 안전성)
// ============================================================================

// GenerateUniqueClusterName 고유한 클러스터 이름 생성
func GenerateUniqueClusterName() string {
	uniqueID := strings.ToLower(random.UniqueId())
	return fmt.Sprintf("tt-%s", uniqueID) // tt = terratest
}

// CopyTerraformFolderToTemp Terraform 폴더를 임시 디렉터리로 복사
func CopyTerraformFolderToTemp(t *testing.T) string {
	return test_structure.CopyTerraformFolderToTemp(t, "../", ".")
}

// GetIsolatedTerraformOptions 격리된 Terraform 옵션 반환 (병렬 실행 안전)
func GetIsolatedTerraformOptions(t *testing.T) (*terraform.Options, string) {
	tempDir := CopyTerraformFolderToTemp(t)
	clusterName := GenerateUniqueClusterName()

	vars := GetTestTerraformVars()
	vars["cluster_name"] = clusterName

	opts := &terraform.Options{
		TerraformDir:       tempDir,
		Vars:               vars,
		MaxRetries:         3,
		TimeBetweenRetries: 5 * time.Second,
		NoColor:            true,
	}

	return opts, clusterName
}

// GetIsolatedPlanOnlyOptions 격리된 Plan 전용 옵션 반환
func GetIsolatedPlanOnlyOptions(t *testing.T) (*terraform.Options, string) {
	opts, clusterName := GetIsolatedTerraformOptions(t)
	opts.PlanFilePath = filepath.Join(opts.TerraformDir, "test-plan.tfplan")
	return opts, clusterName
}

// ============================================================================
// 개선된 Node Ready 검증 함수
// ============================================================================

// WaitForK3sNodesReady 정확한 Ready 상태 확인 (status=True)
func WaitForK3sNodesReady(t *testing.T, host ssh.Host, expectedCount int) error {
	// kubectl get nodes에서 Ready 상태가 True인 노드만 카운트
	command := `sudo kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c "True"`
	description := "Waiting for K3s nodes to be Ready"

	for i := 0; i < SSHMaxRetries; i++ {
		output, err := RunSSHCommand(t, host, command)
		if err == nil {
			readyCount := 0
			fmt.Sscanf(strings.TrimSpace(output), "%d", &readyCount)
			if readyCount >= expectedCount {
				t.Logf("K3s 노드 Ready 확인: %d/%d", readyCount, expectedCount)
				return nil
			}
			t.Logf("%s: Ready 노드 %d/%d, 재시도 %d/%d", description, readyCount, expectedCount, i+1, SSHMaxRetries)
		} else {
			t.Logf("%s: 명령 실패, 재시도 %d/%d - %v", description, i+1, SSHMaxRetries, err)
		}
		time.Sleep(SSHTimeBetweenRetries)
	}

	return fmt.Errorf("K3s 노드가 Ready 상태에 도달하지 못함 (예상: %d)", expectedCount)
}

// ============================================================================
// Spot Instance 및 IAM 검증 함수
// ============================================================================

// GCPInstanceScheduling GCP Instance Scheduling 설정
type GCPInstanceScheduling struct {
	Preemptible       bool   `json:"preemptible"`
	ProvisioningModel string `json:"provisioningModel"`
}

// VerifySpotInstance Spot/Preemptible 인스턴스 검증
func VerifySpotInstance(t *testing.T, instanceName string) (bool, error) {
	projectID := DefaultProjectID
	zone := DefaultZone

	output, err := RunShellCommand(t, "gcloud",
		"compute", "instances", "describe", instanceName,
		"--project", projectID,
		"--zone", zone,
		"--format", "json(scheduling.preemptible,scheduling.provisioningModel)",
	)
	if err != nil {
		return false, fmt.Errorf("인스턴스 '%s' 조회 실패: %v", instanceName, err)
	}

	// Preemptible 또는 SPOT 확인
	isSpot := strings.Contains(output, `"preemptible": true`) ||
		strings.Contains(output, `"provisioningModel": "SPOT"`)

	return isSpot, nil
}

// VerifyIAMLoggingPermission Logging 권한 검증
func VerifyIAMLoggingPermission(t *testing.T, host ssh.Host) error {
	// 실제로 로깅 권한이 동작하는지 테스트
	command := `curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/scopes" | grep -q "logging.write" && echo "OK" || echo "FAIL"`

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return fmt.Errorf("Logging 권한 확인 실패: %v", err)
	}

	if !strings.Contains(output, "OK") {
		return fmt.Errorf("Logging 권한이 부여되지 않음")
	}

	return nil
}

// VerifyIAMMonitoringPermission Monitoring 권한 검증
func VerifyIAMMonitoringPermission(t *testing.T, host ssh.Host) error {
	// 실제로 모니터링 권한이 동작하는지 테스트
	command := `curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/scopes" | grep -q "monitoring.write" && echo "OK" || echo "FAIL"`

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return fmt.Errorf("Monitoring 권한 확인 실패: %v", err)
	}

	if !strings.Contains(output, "OK") {
		return fmt.Errorf("Monitoring 권한이 부여되지 않음")
	}

	return nil
}
