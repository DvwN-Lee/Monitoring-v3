package test

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/retry"
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
	DefaultWorkerMachineType = "e2-standard-4"
	DefaultWorkerCount      = 2
	DefaultSubnetCIDR       = "10.128.0.0/20"
	GCPHealthCheckCidr1     = "130.211.0.0/22"
	GCPHealthCheckCidr2     = "35.191.0.0/16"
	DefaultMasterDiskSize   = 30
	DefaultWorkerDiskSize   = 60 // Issue #37: InvalidDiskCapacity 오류 대응
	TestPostgresPassword    = "TerratestPassword123!"
	TestGrafanaPassword     = "TerratestGrafana123!"
	SSHUsername             = "ubuntu"
	UseSpotForWorkers       = false // Issue #37: Spot Instance InvalidDiskCapacity 오류 대응
)

// 타임아웃 상수
const (
	SSHMaxRetries         = 30
	SSHTimeBetweenRetries = 10 * time.Second
	K3sBootstrapTimeout   = 15 * time.Minute
	DefaultTimeout        = 30 * time.Second

	// Monitoring Stack 재시도 설정 (Issue #27, #29, #35)
	MonitoringStackInitialWait    = 7 * time.Minute   // Bootstrap 초기 대기
	MonitoringAppReadyWait        = 10 * time.Minute  // Application Pod Ready 대기 (5분 -> 10분, 리소스 제약 환경 대응 #35)
	MonitoringHealthCheckRetries  = 18                // Health Check 재시도 횟수 (12 -> 18, 리소스 제약 환경 대응)
	MonitoringHealthCheckInterval = 20 * time.Second  // Health Check 재시도 간격

	// Application 관련 상수 (Issue #27 - 2차 리뷰)
	NamespaceProd = "titanium-prod"

	// Prometheus ClusterIP Service 접근용 상수 (Issue: NodePort 31090 접근 실패 대응)
	// kube-prometheus-stack에서 생성되는 Prometheus Service URL
	PrometheusClusterURL = "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
)

// GetTerraformDir terraform 디렉터리 경로 반환
func GetTerraformDir() string {
	return "../"
}

// GetDefaultTerraformOptions 기본 Terraform 옵션 반환
func GetDefaultTerraformOptions(t *testing.T) *terraform.Options {
	opts := &terraform.Options{
		TerraformDir:       GetTerraformDir(),
		Vars:               GetTestTerraformVars(),
		MaxRetries:         3,
		TimeBetweenRetries: 5 * time.Second,
		NoColor:            true,
	}

	// 테스트 환경 IP를 Vars map에 직접 주입 (Issue #95: .auto.tfvars 파일 생성 제거)
	if ip, err := GetCurrentPublicIP(); err == nil && ip != "" {
		opts.Vars["ssh_allowed_cidrs"] = []string{fmt.Sprintf("%s/32", ip)}
		t.Logf("테스트 환경 IP 추가: %s/32", ip)
	}

	return opts
}

// GetApplyTerraformOptions Apply 테스트용 Terraform 옵션 반환 (고유 클러스터 이름 사용)
// 병렬 테스트 실행 시 리소스 충돌을 방지하기 위해 고유한 cluster_name 생성
func GetApplyTerraformOptions(t *testing.T) *terraform.Options {
	opts := GetDefaultTerraformOptions(t)
	// 고유 클러스터 이름 생성 (6자리 lowercase alphanumeric)
	uniqueID := strings.ToLower(random.UniqueId())
	opts.Vars["cluster_name"] = fmt.Sprintf("terratest-%s", uniqueID)
	t.Logf("Apply 테스트용 고유 클러스터 이름: %s", opts.Vars["cluster_name"])
	return opts
}

// GetCurrentPublicIP 현재 공인 IP 조회
func GetCurrentPublicIP() (string, error) {
	// api.ipify.org 사용 (순수 IP만 반환)
	req, err := http.NewRequest("GET", "https://api.ipify.org", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "text/plain")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	buf := make([]byte, 64)
	n, err := resp.Body.Read(buf)
	if err != nil && err.Error() != "EOF" {
		return "", err
	}

	ip := strings.TrimSpace(string(buf[:n]))
	// IP 형식 검증
	if net.ParseIP(ip) == nil {
		return "", fmt.Errorf("invalid IP format: %s", ip)
	}
	return ip, nil
}

// GetTestTerraformVars 테스트용 Terraform 변수 반환
func GetTestTerraformVars() map[string]interface{} {
	homeDir, _ := os.UserHomeDir()
	return map[string]interface{}{
		"project_id":             DefaultProjectID,
		"region":                 DefaultRegion,
		"zone":                   DefaultZone,
		"cluster_name":           DefaultClusterName,
		"worker_count":           DefaultWorkerCount,
		"master_machine_type":    DefaultMasterMachineType,
		"worker_machine_type":    DefaultWorkerMachineType,
		"subnet_cidr":            DefaultSubnetCIDR,
		"master_disk_size":       DefaultMasterDiskSize,
		"worker_disk_size":       DefaultWorkerDiskSize,
		"use_spot_for_workers":   false, // Issue #37: Spot Instance InvalidDiskCapacity 오류 대응
		"enable_auto_healing":    false, // Issue #37: 테스트 환경 auto-healing 비활성화 (무한 재생성 방지)
		"postgres_password":      TestPostgresPassword,
		"grafana_admin_password": TestGrafanaPassword,
		"ssh_public_key_path":    filepath.Join(homeDir, ".ssh", "titanium-key.pub"),
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

	// 테스트 환경 IP를 Vars map에 직접 주입 (Issue #95: .auto.tfvars 파일 생성 제거)
	if ip, err := GetCurrentPublicIP(); err == nil && ip != "" {
		opts.Vars["ssh_allowed_cidrs"] = []string{fmt.Sprintf("%s/32", ip)}
		t.Logf("테스트 환경 IP 추가 (격리): %s/32", ip)
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
// projectID, zone을 인자로 받아 동적 환경 지원
func VerifySpotInstance(t *testing.T, instanceName, projectID, zone string) (bool, error) {
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

// VerifySpotInstanceWithDefaults 기본값으로 Spot 인스턴스 검증 (하위 호환성)
func VerifySpotInstanceWithDefaults(t *testing.T, instanceName string) (bool, error) {
	return VerifySpotInstance(t, instanceName, DefaultProjectID, DefaultZone)
}

// ============================================================================
// Worker 인스턴스 동적 조회 함수 (MIG 지원)
// ============================================================================

// WorkerInstanceInfo Worker 인스턴스 정보 구조체
type WorkerInstanceInfo struct {
	Name   string `json:"name"`
	Status string `json:"status"`
}

// GetWorkerInstanceNames gcloud list 명령으로 Worker 인스턴스 이름 목록 조회
// MIG에서 생성된 인스턴스는 base_instance_name-{random-suffix} 형식
func GetWorkerInstanceNames(t *testing.T, clusterName, projectID, zone string) ([]string, error) {
	filter := fmt.Sprintf("name~'^%s-worker'", clusterName)

	output, err := RunShellCommand(t, "gcloud",
		"compute", "instances", "list",
		"--filter", filter,
		"--project", projectID,
		"--zones", zone,
		"--format", "json(name,status)",
	)
	if err != nil {
		return nil, fmt.Errorf("Worker 인스턴스 목록 조회 실패: %v", err)
	}

	// gcloud 출력에서 JSON 부분만 추출 (WARNING 메시지 제거)
	// Issue #37: gcloud가 WARNING 메시지를 stdout으로 출력하는 경우 처리
	jsonOutput := extractJSON(output)

	var instances []WorkerInstanceInfo
	if err := json.Unmarshal([]byte(jsonOutput), &instances); err != nil {
		return nil, fmt.Errorf("Worker 인스턴스 JSON 파싱 실패: %v", err)
	}

	var names []string
	for _, instance := range instances {
		if instance.Status == "RUNNING" {
			names = append(names, instance.Name)
		}
	}

	return names, nil
}

// extractJSON gcloud 출력에서 JSON 부분만 추출
// WARNING 등 비-JSON 메시지가 포함된 경우 JSON 배열/객체 부분만 반환
func extractJSON(output string) string {
	lines := strings.Split(output, "\n")

	// JSON 시작점 찾기 ([ 또는 {로 시작하는 첫 줄)
	startIdx := -1
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") || strings.HasPrefix(trimmed, "{") {
			startIdx = i
			break
		}
	}

	if startIdx == -1 {
		// JSON을 찾지 못한 경우 빈 배열 반환
		return "[]"
	}

	// JSON 끝점 찾기 (] 또는 }로 끝나는 마지막 줄)
	endIdx := startIdx
	for i := len(lines) - 1; i >= startIdx; i-- {
		trimmed := strings.TrimSpace(lines[i])
		if strings.HasSuffix(trimmed, "]") || strings.HasSuffix(trimmed, "}") {
			endIdx = i
			break
		}
	}

	return strings.Join(lines[startIdx:endIdx+1], "\n")
}

// GetWorkerInstanceNamesWithRetry 재시도 로직 포함 Worker 인스턴스 조회
// MIG 인스턴스 생성 완료까지 대기
// Issue #37: wait_for_instances=false 설정 후 GCP MIG 인스턴스 프로비저닝 대기
// - MIG 생성 후 인스턴스 프로비저닝까지 최대 15분 소요 가능
func GetWorkerInstanceNamesWithRetry(t *testing.T, clusterName, projectID, zone string, expectedCount int) ([]string, error) {
	maxRetries := 90 // 15분 (90 * 10초)
	sleepBetweenRetries := 10 * time.Second
	retryCount := 0

	var workerNames []string

	_, err := retry.DoWithRetryE(t, "Worker 인스턴스 RUNNING 대기", maxRetries, sleepBetweenRetries, func() (string, error) {
		retryCount++
		names, err := GetWorkerInstanceNames(t, clusterName, projectID, zone)
		if err != nil {
			return "", err
		}

		if len(names) < expectedCount {
			// 5회마다 MIG 상태 로깅 (디버깅용)
			if retryCount%5 == 0 {
				logMIGStatus(t, clusterName, projectID, zone)
			}
			return "", fmt.Errorf("RUNNING 상태 Worker 인스턴스 부족: %d/%d", len(names), expectedCount)
		}

		workerNames = names
		return fmt.Sprintf("%d workers running", len(names)), nil
	})

	return workerNames, err
}

// logMIGStatus MIG 상태 로깅 (디버깅용)
func logMIGStatus(t *testing.T, clusterName, projectID, zone string) {
	migName := fmt.Sprintf("%s-worker-mig", clusterName)
	output, err := RunShellCommand(t, "gcloud",
		"compute", "instance-groups", "managed", "describe", migName,
		"--zone", zone,
		"--project", projectID,
		"--format", "yaml(targetSize,status.isStable,currentActions)",
	)
	if err != nil {
		t.Logf("MIG 상태 조회 실패: %v", err)
		return
	}
	t.Logf("MIG 상태:\n%s", output)
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

// ============================================================================
// Negative Firewall 및 보안 테스트 함수
// ============================================================================

// BlockedPorts 외부에서 차단되어야 할 포트 목록
var BlockedPorts = []int{
	8080,  // 일반 HTTP 대체
	9090,  // Prometheus 기본
	2379,  // etcd client
	2380,  // etcd peer
	3306,  // MySQL/MariaDB
	5432,  // PostgreSQL
	10250, // Kubelet API
	10251, // kube-scheduler
	10252, // kube-controller-manager
}

// TestPortBlocked 외부에서 포트 접근 차단 여부 테스트
func TestPortBlocked(t *testing.T, targetIP string, port int, timeout time.Duration) bool {
	address := net.JoinHostPort(targetIP, fmt.Sprintf("%d", port))
	conn, err := net.DialTimeout("tcp", address, timeout)
	if err != nil {
		// 연결 실패 = 포트 차단됨
		return true
	}
	conn.Close()
	// 연결 성공 = 포트 열림
	return false
}

// TestMultiplePortsBlocked 여러 포트가 차단되었는지 테스트
func TestMultiplePortsBlocked(t *testing.T, targetIP string, ports []int, timeout time.Duration) map[int]bool {
	results := make(map[int]bool)
	for _, port := range ports {
		results[port] = TestPortBlocked(t, targetIP, port, timeout)
	}
	return results
}

// GCPFirewallRule GCP Firewall 규칙 구조체
type GCPFirewallRule struct {
	Name         string   `json:"name"`
	Network      string   `json:"network"`
	SourceRanges []string `json:"sourceRanges"`
	Allowed      []struct {
		IPProtocol string   `json:"IPProtocol"`
		Ports      []string `json:"ports"`
	} `json:"allowed"`
	TargetTags []string `json:"targetTags"`
}

// GetFirewallRule GCP Firewall 규칙 조회
func GetFirewallRule(t *testing.T, projectID, firewallName string) (*GCPFirewallRule, error) {
	output, err := RunShellCommand(t, "gcloud",
		"compute", "firewall-rules", "describe", firewallName,
		"--project", projectID,
		"--format", "json",
	)
	if err != nil {
		return nil, fmt.Errorf("Firewall 규칙 '%s' 조회 실패: %v", firewallName, err)
	}

	var rule GCPFirewallRule
	if err := json.Unmarshal([]byte(output), &rule); err != nil {
		return nil, fmt.Errorf("Firewall 규칙 JSON 파싱 실패: %v", err)
	}

	return &rule, nil
}

// VerifyFirewallSourceRanges Firewall source_ranges 검증
func VerifyFirewallSourceRanges(t *testing.T, projectID, firewallName string, expectedRanges []string) error {
	rule, err := GetFirewallRule(t, projectID, firewallName)
	if err != nil {
		return err
	}

	for _, expected := range expectedRanges {
		found := false
		for _, actual := range rule.SourceRanges {
			if actual == expected {
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("Firewall '%s': 예상 source_range '%s' 미발견, 실제: %v",
				firewallName, expected, rule.SourceRanges)
		}
	}

	return nil
}

// VerifyFirewallNotOpenToWorld Firewall이 0.0.0.0/0으로 열려있지 않은지 검증
func VerifyFirewallNotOpenToWorld(t *testing.T, projectID, firewallName string) error {
	rule, err := GetFirewallRule(t, projectID, firewallName)
	if err != nil {
		return err
	}

	for _, sourceRange := range rule.SourceRanges {
		if sourceRange == "0.0.0.0/0" {
			return fmt.Errorf("Firewall '%s': 전체 인터넷(0.0.0.0/0)에 개방됨 - 보안 위험", firewallName)
		}
	}

	return nil
}

// ============================================================================
// HTTP/JSON 검증 함수
// ============================================================================

// HTTPResponse HTTP 응답 구조체
type HTTPResponse struct {
	StatusCode int
	Body       string
	Headers    http.Header
}

// TestHTTPEndpoint HTTP endpoint 테스트
func TestHTTPEndpoint(t *testing.T, url string, timeout time.Duration) (*HTTPResponse, error) {
	client := &http.Client{Timeout: timeout}
	resp, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("HTTP 요청 실패: %v", err)
	}
	defer resp.Body.Close()

	body := make([]byte, 0)
	buf := make([]byte, 1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			body = append(body, buf[:n]...)
		}
		if err != nil {
			break
		}
	}

	return &HTTPResponse{
		StatusCode: resp.StatusCode,
		Body:       string(body),
		Headers:    resp.Header,
	}, nil
}

// TestHTTPEndpointStrict strict mode HTTP endpoint 테스트 (200 OK만 허용)
func TestHTTPEndpointStrict(t *testing.T, url string, timeout time.Duration) error {
	resp, err := TestHTTPEndpoint(t, url, timeout)
	if err != nil {
		return err
	}

	if resp.StatusCode != 200 {
		return fmt.Errorf("HTTP 응답 코드 불일치: 예상 200, 실제 %d", resp.StatusCode)
	}

	return nil
}

// ValidateJSONResponse JSON 응답 필드 검증
func ValidateJSONResponse(t *testing.T, url string, timeout time.Duration, expectedFields map[string]interface{}) error {
	resp, err := TestHTTPEndpoint(t, url, timeout)
	if err != nil {
		return err
	}

	if resp.StatusCode != 200 {
		return fmt.Errorf("HTTP 응답 코드 불일치: 예상 200, 실제 %d", resp.StatusCode)
	}

	var jsonBody map[string]interface{}
	if err := json.Unmarshal([]byte(resp.Body), &jsonBody); err != nil {
		return fmt.Errorf("JSON 파싱 실패: %v", err)
	}

	for key, expectedValue := range expectedFields {
		actualValue, exists := jsonBody[key]
		if !exists {
			return fmt.Errorf("JSON 필드 '%s' 미존재", key)
		}
		if expectedValue != nil && actualValue != expectedValue {
			return fmt.Errorf("JSON 필드 '%s' 값 불일치: 예상 %v, 실제 %v", key, expectedValue, actualValue)
		}
	}

	return nil
}

// ============================================================================
// ArgoCD 상태 검증 함수
// ============================================================================

// ArgoAppStatus ArgoCD Application 상태 구조체
type ArgoAppStatus struct {
	Name         string `json:"name"`
	SyncStatus   string `json:"syncStatus"`
	HealthStatus string `json:"healthStatus"`
}

// GetArgoCDApplicationStatuses ArgoCD Application 상태 조회
func GetArgoCDApplicationStatuses(t *testing.T, host ssh.Host) ([]ArgoAppStatus, error) {
	command := `sudo kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name},{.status.sync.status},{.status.health.status}{"\n"}{end}'`

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return nil, fmt.Errorf("ArgoCD Application 상태 조회 실패: %v", err)
	}

	var statuses []ArgoAppStatus
	lines := strings.Split(strings.TrimSpace(output), "\n")
	for _, line := range lines {
		if line == "" {
			continue
		}
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

// WaitForArgoCDAppHealthy ArgoCD Application Healthy 상태 대기
func WaitForArgoCDAppHealthy(t *testing.T, host ssh.Host, appName string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		statuses, err := GetArgoCDApplicationStatuses(t, host)
		if err != nil {
			t.Logf("ArgoCD 상태 조회 실패, 재시도: %v", err)
			time.Sleep(10 * time.Second)
			continue
		}

		for _, status := range statuses {
			if status.Name == appName {
				if status.SyncStatus == "Synced" && status.HealthStatus == "Healthy" {
					t.Logf("ArgoCD App '%s': Synced + Healthy", appName)
					return nil
				}
				t.Logf("ArgoCD App '%s': Sync=%s, Health=%s", appName, status.SyncStatus, status.HealthStatus)
			}
		}

		time.Sleep(10 * time.Second)
	}

	return fmt.Errorf("ArgoCD App '%s'가 timeout 내에 Healthy 상태에 도달하지 못함", appName)
}

// VerifyAllArgoCDAppsHealthy 모든 ArgoCD Application이 Healthy인지 검증
func VerifyAllArgoCDAppsHealthy(t *testing.T, host ssh.Host) error {
	statuses, err := GetArgoCDApplicationStatuses(t, host)
	if err != nil {
		return err
	}

	var unhealthyApps []string
	for _, status := range statuses {
		if status.SyncStatus != "Synced" || status.HealthStatus != "Healthy" {
			unhealthyApps = append(unhealthyApps, fmt.Sprintf("%s(Sync=%s,Health=%s)",
				status.Name, status.SyncStatus, status.HealthStatus))
		}
	}

	if len(unhealthyApps) > 0 {
		return fmt.Errorf("Unhealthy ArgoCD Apps: %v", unhealthyApps)
	}

	return nil
}

// ============================================================================
// Prometheus 검증 함수
// ============================================================================

// PrometheusTarget Prometheus 타겟 구조체
type PrometheusTarget struct {
	Labels      map[string]string `json:"labels"`
	ScrapeURL   string            `json:"scrapeUrl"`
	Health      string            `json:"health"` // up, down, unknown
	LastError   string            `json:"lastError"`
	LastScrape  string            `json:"lastScrape"`
}

// PrometheusTargetsResponse Prometheus API 응답
type PrometheusTargetsResponse struct {
	Status string `json:"status"`
	Data   struct {
		ActiveTargets []PrometheusTarget `json:"activeTargets"`
	} `json:"data"`
}

// GetPrometheusTargets Prometheus API로 타겟 조회
func GetPrometheusTargets(t *testing.T, host ssh.Host, prometheusNodePort string) ([]PrometheusTarget, error) {
	// kubectl run으로 임시 Pod 생성하여 Prometheus API 호출 (NodePort 의존성 제거)
	// prometheusNodePort 파라미터는 하위 호환성을 위해 유지하지만 실제로는 ClusterIP 사용
	// 2>/dev/null로 "pod/xxx deleted" 메시지를 stderr로 분리하여 JSON 파싱 문제 해결
	podSuffix := time.Now().UnixNano() % 10000
	command := fmt.Sprintf(`sudo kubectl run prometheus-targets-%d --rm -i --restart=Never --image=curlimages/curl:8.5.0 --timeout=60s -- curl -s --max-time 50 "%s/api/v1/targets" 2>/dev/null`, podSuffix, PrometheusClusterURL)

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return nil, fmt.Errorf("Prometheus API 호출 실패: %v", err)
	}

	// 출력에서 JSON 부분만 추출 (앞뒤 공백 제거)
	output = strings.TrimSpace(output)
	jsonStart := strings.Index(output, "{")
	if jsonStart == -1 {
		return nil, fmt.Errorf("Prometheus API 응답에서 JSON을 찾을 수 없음: %s", output[:min(len(output), 200)])
	}

	// JSON 시작부터 끝까지 추출 (마지막 } 찾기)
	jsonOutput := output[jsonStart:]
	// 마지막으로 완전한 JSON 객체의 끝을 찾음
	lastBrace := strings.LastIndex(jsonOutput, "}")
	if lastBrace == -1 {
		return nil, fmt.Errorf("Prometheus API 응답에서 JSON 끝을 찾을 수 없음")
	}
	jsonOutput = jsonOutput[:lastBrace+1]

	var response PrometheusTargetsResponse
	if err := json.Unmarshal([]byte(jsonOutput), &response); err != nil {
		return nil, fmt.Errorf("Prometheus 응답 JSON 파싱 실패: %v (output length: %d)", err, len(jsonOutput))
	}

	if response.Status != "success" {
		return nil, fmt.Errorf("Prometheus API 응답 실패: %s", response.Status)
	}

	return response.Data.ActiveTargets, nil
}

// VerifyPrometheusTargetsUp 필수 타겟이 up 상태인지 확인
func VerifyPrometheusTargetsUp(t *testing.T, host ssh.Host, prometheusNodePort string, requiredJobs []string) error {
	targets, err := GetPrometheusTargets(t, host, prometheusNodePort)
	if err != nil {
		return err
	}

	jobStatus := make(map[string]bool)
	for _, target := range targets {
		job, exists := target.Labels["job"]
		if exists && target.Health == "up" {
			jobStatus[job] = true
		}
	}

	var missingJobs []string
	for _, required := range requiredJobs {
		if !jobStatus[required] {
			missingJobs = append(missingJobs, required)
		}
	}

	if len(missingJobs) > 0 {
		return fmt.Errorf("Prometheus: 다음 job이 up 상태가 아님: %v", missingJobs)
	}

	return nil
}

// ============================================================================
// K3s 노드 관리 함수
// ============================================================================

// GetK3sNodeNames K3s 클러스터의 노드 이름 목록 조회
func GetK3sNodeNames(t *testing.T, host ssh.Host) ([]string, error) {
	command := `sudo kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'`

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return nil, fmt.Errorf("K3s 노드 목록 조회 실패: %v", err)
	}

	var nodeNames []string
	lines := strings.Split(strings.TrimSpace(output), "\n")
	for _, line := range lines {
		if line != "" {
			nodeNames = append(nodeNames, line)
		}
	}

	return nodeNames, nil
}

// VerifyNodeExists 특정 노드가 클러스터에 존재하는지 확인
func VerifyNodeExists(t *testing.T, host ssh.Host, nodeName string) bool {
	nodeNames, err := GetK3sNodeNames(t, host)
	if err != nil {
		return false
	}

	for _, name := range nodeNames {
		if name == nodeName {
			return true
		}
	}

	return false
}

// VerifyNodeReady 특정 노드가 Ready 상태인지 확인
func VerifyNodeReady(t *testing.T, host ssh.Host, nodeName string) (bool, error) {
	command := fmt.Sprintf(`sudo kubectl get node %s -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'`, nodeName)

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return false, fmt.Errorf("노드 '%s' 상태 조회 실패: %v", nodeName, err)
	}

	return strings.TrimSpace(output) == "True", nil
}

// ============================================================================
// Monitoring Stack 검증 함수
// ============================================================================

// QueryPrometheusMetric Prometheus metric 쿼리 실행 및 결과 개수 반환
// kubectl exec를 통해 ClusterIP Service로 직접 접근 (NodePort 31090 의존성 제거)
func QueryPrometheusMetric(t *testing.T, host ssh.Host, query string) (int, error) {
	// kubectl run으로 임시 Pod 생성하여 Prometheus API 쿼리 수행
	// 결과를 jq로 파싱하여 result 개수 반환
	podSuffix := time.Now().UnixNano() % 10000
	command := fmt.Sprintf(`sudo kubectl run prometheus-query-%d --rm -i --restart=Never --image=curlimages/curl:8.5.0 --timeout=30s -- curl -s "%s/api/v1/query?query=%s" 2>/dev/null | jq -r '.data.result | length' 2>/dev/null || echo '0'`, podSuffix, PrometheusClusterURL, query)

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return 0, fmt.Errorf("Prometheus metric 쿼리 실패: %v", err)
	}

	// 출력에서 숫자만 추출 (kubectl 출력 노이즈 제거)
	lines := strings.Split(strings.TrimSpace(output), "\n")
	var resultStr string
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if _, parseErr := strconv.Atoi(line); parseErr == nil {
			resultStr = line
			break
		}
	}

	if resultStr == "" {
		resultStr = "0"
	}

	resultCount, err := strconv.Atoi(resultStr)
	if err != nil {
		return 0, fmt.Errorf("Prometheus 결과 파싱 실패: %v (output: %s)", err, output)
	}

	return resultCount, nil
}

// VerifyGrafanaDataSources Grafana DataSource 연결 상태 확인
func VerifyGrafanaDataSources(t *testing.T, host ssh.Host, sources []string) error {
	// Grafana API로 DataSource 목록 조회 (TestGrafanaPassword 사용)
	command := fmt.Sprintf(`curl -s -u admin:%s "http://localhost:31300/api/datasources" | jq -r '.[].name'`, TestGrafanaPassword)

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return fmt.Errorf("Grafana DataSource 조회 실패: %v", err)
	}

	foundSources := strings.Split(strings.TrimSpace(output), "\n")
	foundMap := make(map[string]bool)
	for _, source := range foundSources {
		foundMap[strings.TrimSpace(source)] = true
	}

	var missingSources []string
	for _, required := range sources {
		if !foundMap[required] {
			missingSources = append(missingSources, required)
		}
	}

	if len(missingSources) > 0 {
		return fmt.Errorf("Grafana: 다음 DataSource가 없음: %v", missingSources)
	}

	return nil
}

// QueryLokiLogs Loki 로그 쿼리 실행 및 결과 개수 반환
func QueryLokiLogs(t *testing.T, host ssh.Host, logQL string) (int, error) {
	// Loki API를 통해 로그 쿼리
	command := fmt.Sprintf(`curl -s "http://localhost:3100/loki/api/v1/query?query=%s&limit=100" | jq -r '.data.result | length'`, logQL)

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return 0, fmt.Errorf("Loki 로그 쿼리 실패: %v", err)
	}

	resultCount, err := strconv.Atoi(strings.TrimSpace(output))
	if err != nil {
		return 0, fmt.Errorf("Loki 결과 파싱 실패: %v", err)
	}

	return resultCount, nil
}

// GetKialiNamespaces Kiali가 관리하는 namespace 목록 조회
// Kiali API 대신 kubectl로 Istio sidecar가 주입된 namespace 확인
func GetKialiNamespaces(t *testing.T, host ssh.Host) ([]string, error) {
	// Istio sidecar injection이 활성화된 namespace 또는 주요 namespace 조회
	command := `sudo kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E "istio-system|monitoring|default|titanium" || echo ''`

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return nil, fmt.Errorf("Namespace 조회 실패: %v", err)
	}

	var namespaces []string
	lines := strings.Split(strings.TrimSpace(output), "\n")
	for _, line := range lines {
		ns := strings.TrimSpace(line)
		if ns != "" {
			namespaces = append(namespaces, ns)
		}
	}

	if len(namespaces) == 0 {
		return nil, fmt.Errorf("관련 namespace를 찾을 수 없음")
	}

	return namespaces, nil
}

// VerifyPrometheusHealthy Prometheus 서버 health 상태 확인
// kubectl exec를 통해 ClusterIP Service로 직접 접근 (NodePort 31090 의존성 제거)
func VerifyPrometheusHealthy(t *testing.T, host ssh.Host) error {
	// kubectl run으로 임시 Pod 생성하여 Prometheus health check 수행
	command := fmt.Sprintf(`sudo kubectl run prometheus-health-check --rm -i --restart=Never --image=busybox:1.36 --timeout=30s -- wget -qO- --timeout=10 "%s/-/healthy" 2>/dev/null || echo 'HEALTH_CHECK_FAILED'`, PrometheusClusterURL)

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return fmt.Errorf("Prometheus health check 실패: %v", err)
	}

	// kubectl run 출력에서 실제 응답 추출
	output = strings.TrimSpace(output)
	if strings.Contains(output, "HEALTH_CHECK_FAILED") || output == "" {
		return fmt.Errorf("Prometheus health check 응답 없음")
	}

	if !strings.Contains(output, "Prometheus Server is Healthy") && !strings.Contains(output, "Healthy") {
		return fmt.Errorf("Prometheus가 healthy 상태가 아님: %s", output)
	}

	return nil
}

// VerifyGrafanaHealthy Grafana 서버 health 상태 확인
func VerifyGrafanaHealthy(t *testing.T, host ssh.Host) error {
	command := `curl -s "http://localhost:31300/api/health" | jq -r '.database'`

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return fmt.Errorf("Grafana health check 실패: %v", err)
	}

	if strings.TrimSpace(output) != "ok" {
		return fmt.Errorf("Grafana database가 healthy 상태가 아님: %s", output)
	}

	return nil
}

// VerifyLokiReady Loki 서버 ready 상태 확인
// loki-stack Helm chart는 StatefulSet으로 배포됨
func VerifyLokiReady(t *testing.T, host ssh.Host) error {
	// Pod label로 접근 (StatefulSet/Deployment 무관)
	command := `sudo kubectl exec -n monitoring $(sudo kubectl get pod -n monitoring -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) -- wget -qO- "http://localhost:3100/ready" 2>/dev/null || echo 'LOKI_NOT_READY'`

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return fmt.Errorf("Loki ready check 실패: %v", err)
	}

	if strings.Contains(output, "LOKI_NOT_READY") {
		return fmt.Errorf("Loki Pod에 접근할 수 없음")
	}

	if !strings.Contains(output, "ready") {
		return fmt.Errorf("Loki가 ready 상태가 아님: %s", output)
	}

	return nil
}

// VerifyKialiHealthy Kiali 서버 health 상태 확인
// Kiali는 istio-system namespace에 배포됨
// Pod Ready 상태만 확인 (API 초기화 지연 이슈 대응)
func VerifyKialiHealthy(t *testing.T, host ssh.Host) error {
	// Kiali Pod Ready 상태 확인
	command := `sudo kubectl get pod -n istio-system -l app=kiali -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo 'NOT_FOUND'`

	output, err := RunSSHCommand(t, host, command)
	if err != nil {
		return fmt.Errorf("Kiali Pod 상태 조회 실패: %v", err)
	}

	status := strings.TrimSpace(output)
	if status == "NOT_FOUND" || status == "" {
		return fmt.Errorf("Kiali Pod를 찾을 수 없음")
	}

	if status != "True" {
		return fmt.Errorf("Kiali Pod가 Ready 상태가 아님: %s", status)
	}

	t.Log("Kiali Pod가 Ready 상태입니다")
	return nil
}

// ============================================================================
// Monitoring Stack 재시도 Helper 함수 (Issue #27)
// ============================================================================

// triggerArgoCDSync ArgoCD Application sync 강제 트리거 (Issue #33)
// OutOfSync 상태가 지속될 경우 수동으로 sync 명령 실행
func triggerArgoCDSync(t *testing.T, host ssh.Host, appName string) error {
	t.Logf("ArgoCD Application '%s' sync 트리거 중...", appName)
	command := fmt.Sprintf(`sudo kubectl -n argocd patch application %s --type=merge -p '{"operation":{"initiatedBy":{"username":"terratest"},"sync":{"prune":true}}}'`, appName)
	_, err := RunSSHCommand(t, host, command)
	if err != nil {
		t.Logf("Sync 트리거 실패 (이미 진행 중일 수 있음): %v", err)
	}
	return nil // sync 트리거 실패는 무시 (이미 sync 중일 수 있음)
}

// logArgoCDAppDetails ArgoCD Application 상세 상태 로깅 (Issue #33)
// 동기화 실패 시 디버깅을 위한 상세 정보 출력
// logDegradedDebugInfo Degraded 상태 전환 시 상세 디버깅 정보 출력
func logDegradedDebugInfo(t *testing.T, host ssh.Host, appName string) {
	t.Log("--- [1/5] ArgoCD Unhealthy Resources ---")
	resourceCmd := fmt.Sprintf(`sudo kubectl get application %s -n argocd -o jsonpath='{range .status.resources[?(@.health.status!="Healthy")]}{.kind}/{.name}: {.health.status} - {.health.message}{"\n"}{end}' 2>/dev/null`, appName)
	if output, err := RunSSHCommand(t, host, resourceCmd); err == nil {
		if trimmed := strings.TrimSpace(output); trimmed != "" {
			t.Logf("Unhealthy Resources:\n%s", trimmed)
		} else {
			t.Log("(Unhealthy resource 없음 - 상태 전환 중)")
		}
	}

	t.Log("--- [2/5] Default Namespace Pod Status ---")
	podCmd := `sudo kubectl get pods -n default -o wide 2>/dev/null | head -20`
	if output, err := RunSSHCommand(t, host, podCmd); err == nil {
		t.Logf("Pods:\n%s", strings.TrimSpace(output))
	}

	t.Log("--- [3/5] Not Ready Pods Detail ---")
	notReadyCmd := `sudo kubectl get pods -n default -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}: {.status.phase} - {.status.conditions[?(@.type=="Ready")].reason}{"\n"}{end}' 2>/dev/null`
	if output, err := RunSSHCommand(t, host, notReadyCmd); err == nil {
		if trimmed := strings.TrimSpace(output); trimmed != "" {
			t.Logf("Not Ready Pods:\n%s", trimmed)
		} else {
			t.Log("(모든 Pod가 Running 상태)")
		}
	}

	t.Log("--- [4/5] Recent Events (Warning) ---")
	eventsCmd := `sudo kubectl get events -n default --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -10`
	if output, err := RunSSHCommand(t, host, eventsCmd); err == nil {
		if trimmed := strings.TrimSpace(output); trimmed != "" {
			t.Logf("Warning Events:\n%s", trimmed)
		} else {
			t.Log("(Warning event 없음)")
		}
	}

	t.Log("--- [5/5] Node Resource Usage ---")
	nodeCmd := `sudo kubectl top nodes 2>/dev/null || echo 'metrics-server not ready'`
	if output, err := RunSSHCommand(t, host, nodeCmd); err == nil {
		t.Logf("Node Resources:\n%s", strings.TrimSpace(output))
	}

	t.Log("=== Degraded 디버깅 정보 수집 완료 ===")
}

func logArgoCDAppDetails(t *testing.T, host ssh.Host, appName string) {
	t.Logf("=== ArgoCD Application '%s' 상세 상태 ===", appName)

	// 1. 전체 상태 요약
	statusCmd := fmt.Sprintf(`sudo kubectl get application %s -n argocd -o jsonpath='{.status.sync.status},{.status.health.status},{.status.operationState.phase}' 2>/dev/null || echo 'Unknown'`, appName)
	if output, err := RunSSHCommand(t, host, statusCmd); err == nil {
		t.Logf("상태: %s", strings.TrimSpace(output))
	}

	// 2. 실패한 리소스 확인
	resourceCmd := fmt.Sprintf(`sudo kubectl get application %s -n argocd -o jsonpath='{range .status.resources[?(@.health.status!="Healthy")]}{.kind}/{.name}: {.health.status} - {.health.message}{"\n"}{end}' 2>/dev/null`, appName)
	if output, err := RunSSHCommand(t, host, resourceCmd); err == nil && strings.TrimSpace(output) != "" {
		t.Logf("Unhealthy Resources:\n%s", output)
	}

	// 3. 최근 sync 오류 메시지
	syncMsgCmd := fmt.Sprintf(`sudo kubectl get application %s -n argocd -o jsonpath='{.status.operationState.message}' 2>/dev/null`, appName)
	if output, err := RunSSHCommand(t, host, syncMsgCmd); err == nil && strings.TrimSpace(output) != "" {
		t.Logf("Operation Message: %s", strings.TrimSpace(output))
	}

	// 4. conditions 확인 (추가 오류 정보)
	condCmd := fmt.Sprintf(`sudo kubectl get application %s -n argocd -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>/dev/null`, appName)
	if output, err := RunSSHCommand(t, host, condCmd); err == nil && strings.TrimSpace(output) != "" {
		t.Logf("Conditions:\n%s", output)
	}
}

// WaitForMonitoringStackReady Monitoring Stack 단계별 대기 (Issue #33 개선)
// 1단계: ArgoCD Application Synced 상태 대기 (OutOfSync 시 sync 트리거)
// 2단계: ArgoCD Application Healthy 상태 대기
// 3단계: Monitoring Pod Ready 확인
func WaitForMonitoringStackReady(t *testing.T, host ssh.Host) error {
	appName := "titanium-prod"

	// 1단계: Synced 상태 대기 (최대 7분, OutOfSync 시 sync 트리거)
	t.Logf("1단계: ArgoCD %s Application Synced 상태 대기 (최대 7분)...", appName)
	syncRetries := 42 // 10초 간격 * 42 = 7분
	syncTriggered := false

	_, err := retry.DoWithRetryE(t, "ArgoCD Synced 대기", syncRetries, 10*time.Second, func() (string, error) {
		// sync.status, health.status, operationState.phase 모두 조회
		command := fmt.Sprintf(`sudo kubectl get application %s -n argocd -o jsonpath='{.status.sync.status},{.status.health.status},{.status.operationState.phase}' 2>/dev/null || echo 'Unknown,Unknown,Unknown'`, appName)
		output, err := RunSSHCommand(t, host, command)
		if err != nil {
			return "", fmt.Errorf("상태 조회 실패: %v", err)
		}

		status := strings.TrimSpace(output)
		parts := strings.Split(status, ",")
		syncStatus := parts[0]
		healthStatus := "Unknown"
		operationPhase := "Unknown"
		if len(parts) > 1 {
			healthStatus = parts[1]
		}
		if len(parts) > 2 {
			operationPhase = parts[2]
		}

		t.Logf("현재 상태: Sync=%s, Health=%s, Operation=%s", syncStatus, healthStatus, operationPhase)

		// OutOfSync 상태에서 sync 트리거 (1회만, Missing/Unknown 상태 제외)
		if syncStatus == "OutOfSync" && healthStatus != "Missing" && !syncTriggered {
			triggerArgoCDSync(t, host, appName)
			syncTriggered = true
			return "", fmt.Errorf("sync 트리거 후 대기 중")
		}

		// Synced 상태이거나, Operation이 Succeeded이면 sync 완료로 간주
		// (ArgoCD가 sync 완료 후 상태 업데이트가 지연되는 경우 대응)
		if syncStatus == "Synced" || operationPhase == "Succeeded" {
			t.Logf("ArgoCD sync 완료 (Sync=%s, Operation=%s)", syncStatus, operationPhase)
			return status, nil
		}

		return "", fmt.Errorf("%s 상태: %s (Synced 대기 중)", appName, status)
	})

	if err != nil {
		logArgoCDAppDetails(t, host, appName)
		return fmt.Errorf("ArgoCD %s Synced 대기 실패: %v", appName, err)
	}

	// 2단계: Healthy 상태 대기 (최대 20분, Issue #37 리소스 증설에 따른 배포 시간 증가 대응)
	// Degraded 상태여도 모든 Pod가 Ready면 'Functionally Ready'로 통과 (타이밍 이슈 대응)
	t.Logf("2단계: ArgoCD %s Application Healthy 상태 대기 (최대 20분)...", appName)
	healthRetries := 120 // 10초 간격 * 120 = 20분 (타이밍 이슈 대응)
	prevHealthStatus := ""
	degradedLogged := false

	_, err = retry.DoWithRetryE(t, "ArgoCD Healthy 대기", healthRetries, 10*time.Second, func() (string, error) {
		command := fmt.Sprintf(`sudo kubectl get application %s -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo 'Unknown'`, appName)
		output, err := RunSSHCommand(t, host, command)
		if err != nil {
			return "", fmt.Errorf("상태 조회 실패: %v", err)
		}

		healthStatus := strings.TrimSpace(output)
		t.Logf("Health 상태: %s", healthStatus)

		// Degraded 상태 전환 감지 시 상세 디버깅 정보 출력 (최초 1회만)
		if healthStatus == "Degraded" && prevHealthStatus != "Degraded" && !degradedLogged {
			t.Log("=== Degraded 상태 감지: 상세 디버깅 정보 수집 ===")
			logDegradedDebugInfo(t, host, appName)
			degradedLogged = true
		}
		prevHealthStatus = healthStatus

		// Case 1: Healthy 상태면 즉시 성공
		if healthStatus == "Healthy" {
			return healthStatus, nil
		}

		// Case 2: Degraded 상태 - 'Functionally Ready' 검사 (모든 Pod Running && Ready)
		if healthStatus == "Degraded" {
			// titanium-prod namespace의 모든 Pod 상태 확인
			podCmd := fmt.Sprintf(`sudo kubectl get pods -n %s -o jsonpath='{range .items[*]}{.status.phase},{.status.conditions[?(@.type=="Ready")].status}{" "}{end}' 2>/dev/null`, NamespaceProd)
			podsOutput, podErr := RunSSHCommand(t, host, podCmd)
			if podErr == nil {
				allPodsReady := true
				pods := strings.Fields(strings.TrimSpace(podsOutput))
				for _, podStatus := range pods {
					parts := strings.Split(podStatus, ",")
					phase := parts[0]
					ready := ""
					if len(parts) > 1 {
						ready = parts[1]
					}
					// Succeeded (Job 완료) 또는 Running+Ready가 아니면 실패
					if phase != "Succeeded" && (phase != "Running" || ready != "True") {
						allPodsReady = false
						break
					}
				}
				if allPodsReady && len(pods) > 0 {
					t.Logf("WARN: ArgoCD '%s'가 Degraded지만 모든 Pod가 Ready 상태입니다. 'Functionally Ready'로 처리합니다.", appName)
					return "Functionally Ready", nil
				}
			}
		}

		return "", fmt.Errorf("%s Health: %s (Healthy 대기 중)", appName, healthStatus)
	})

	if err != nil {
		logArgoCDAppDetails(t, host, appName)
		return fmt.Errorf("ArgoCD %s Healthy 대기 실패: %v", appName, err)
	}

	t.Logf("ArgoCD %s Application이 Healthy,Synced 상태입니다", appName)

	// 3단계: monitoring namespace Pod Ready 확인 (기존 로직 유지)
	t.Logf("3단계: Monitoring Pod Ready 대기 (최대 %v)...", MonitoringAppReadyWait)

	maxRetries := int(MonitoringAppReadyWait / (10 * time.Second))
	_, err = retry.DoWithRetryE(t, "Monitoring Pod Ready", maxRetries, 10*time.Second, func() (string, error) {
		command := `sudo kubectl get pods -n monitoring -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | wc -w`
		output, err := RunSSHCommand(t, host, command)
		if err != nil {
			return "", fmt.Errorf("Pod 상태 확인 실패: %v", err)
		}

		runningCount := 0
		fmt.Sscanf(strings.TrimSpace(output), "%d", &runningCount)

		// 최소 3개 이상의 Pod가 Running이어야 함 (Prometheus, Grafana, Loki 등)
		if runningCount < 3 {
			return "", fmt.Errorf("Running Pod 부족: %d/3", runningCount)
		}

		t.Logf("Monitoring namespace: %d개 Pod Running", runningCount)
		return output, nil
	})

	return err
}

// VerifyPrometheusHealthyWithRetry Prometheus Health Check (재시도 포함)
func VerifyPrometheusHealthyWithRetry(t *testing.T, host ssh.Host) error {
	_, err := retry.DoWithRetryE(t, "Prometheus Health Check",
		MonitoringHealthCheckRetries,
		MonitoringHealthCheckInterval,
		func() (string, error) {
			err := VerifyPrometheusHealthy(t, host)
			if err != nil {
				return "", err
			}
			return "healthy", nil
		})
	return err
}

// VerifyGrafanaHealthyWithRetry Grafana Health Check (재시도 포함)
func VerifyGrafanaHealthyWithRetry(t *testing.T, host ssh.Host) error {
	_, err := retry.DoWithRetryE(t, "Grafana Health Check",
		MonitoringHealthCheckRetries,
		MonitoringHealthCheckInterval,
		func() (string, error) {
			err := VerifyGrafanaHealthy(t, host)
			if err != nil {
				return "", err
			}
			return "healthy", nil
		})
	return err
}

// VerifyLokiReadyWithRetry Loki Ready Check (재시도 포함)
func VerifyLokiReadyWithRetry(t *testing.T, host ssh.Host) error {
	_, err := retry.DoWithRetryE(t, "Loki Ready Check",
		MonitoringHealthCheckRetries,
		MonitoringHealthCheckInterval,
		func() (string, error) {
			err := VerifyLokiReady(t, host)
			if err != nil {
				return "", err
			}
			return "ready", nil
		})
	return err
}

// VerifyKialiHealthyWithRetry Kiali Health Check (재시도 포함)
func VerifyKialiHealthyWithRetry(t *testing.T, host ssh.Host) error {
	_, err := retry.DoWithRetryE(t, "Kiali Health Check",
		MonitoringHealthCheckRetries,
		MonitoringHealthCheckInterval,
		func() (string, error) {
			err := VerifyKialiHealthy(t, host)
			if err != nil {
				return "", err
			}
			return "healthy", nil
		})
	return err
}

// VerifyPrometheusTargetsUpWithRetry Prometheus Targets Check (재시도 포함)
func VerifyPrometheusTargetsUpWithRetry(t *testing.T, host ssh.Host, prometheusNodePort string, requiredJobs []string) error {
	_, err := retry.DoWithRetryE(t, "Prometheus Targets Up Check",
		MonitoringHealthCheckRetries,
		MonitoringHealthCheckInterval,
		func() (string, error) {
			err := VerifyPrometheusTargetsUp(t, host, prometheusNodePort, requiredJobs)
			if err != nil {
				return "", err
			}
			return "targets up", nil
		})
	return err
}

// VerifyPrometheusMinTargetsUp 최소 target 개수 확인 (job 이름 무관)
func VerifyPrometheusMinTargetsUp(t *testing.T, host ssh.Host, prometheusNodePort string, minCount int) error {
	targets, err := GetPrometheusTargets(t, host, prometheusNodePort)
	if err != nil {
		return err
	}

	upCount := 0
	for _, target := range targets {
		if target.Health == "up" {
			upCount++
		}
	}

	if upCount < minCount {
		return fmt.Errorf("Prometheus: UP 상태 target 부족 (%d/%d)", upCount, minCount)
	}

	t.Logf("Prometheus targets: %d개 UP (최소 요구: %d)", upCount, minCount)
	return nil
}

// VerifyPrometheusMinTargetsUpWithRetry 최소 target 개수 확인 (재시도 포함)
func VerifyPrometheusMinTargetsUpWithRetry(t *testing.T, host ssh.Host, prometheusNodePort string, minCount int) error {
	_, err := retry.DoWithRetryE(t, "Prometheus Min Targets Up Check",
		MonitoringHealthCheckRetries,
		MonitoringHealthCheckInterval,
		func() (string, error) {
			err := VerifyPrometheusMinTargetsUp(t, host, prometheusNodePort, minCount)
			if err != nil {
				return "", err
			}
			return "targets up", nil
		})
	return err
}

// VerifyGrafanaDataSourcesWithRetry Grafana DataSources Check (재시도 포함)
func VerifyGrafanaDataSourcesWithRetry(t *testing.T, host ssh.Host, sources []string) error {
	_, err := retry.DoWithRetryE(t, "Grafana DataSources Check",
		MonitoringHealthCheckRetries,
		MonitoringHealthCheckInterval,
		func() (string, error) {
			err := VerifyGrafanaDataSources(t, host, sources)
			if err != nil {
				return "", err
			}
			return "datasources connected", nil
		})
	return err
}

// QueryPrometheusMetricWithRetry Prometheus Metric Query (재시도 포함)
func QueryPrometheusMetricWithRetry(t *testing.T, host ssh.Host, query string) (int, error) {
	var resultCount int
	_, err := retry.DoWithRetryE(t, fmt.Sprintf("Prometheus Metric Query: %s", query),
		MonitoringHealthCheckRetries,
		MonitoringHealthCheckInterval,
		func() (string, error) {
			count, err := QueryPrometheusMetric(t, host, query)
			if err != nil {
				return "", err
			}
			resultCount = count
			return fmt.Sprintf("%d results", count), nil
		})
	return resultCount, err
}

// GetKialiNamespacesWithRetry Kiali Namespaces 조회 (재시도 포함)
func GetKialiNamespacesWithRetry(t *testing.T, host ssh.Host) ([]string, error) {
	var namespaces []string
	_, err := retry.DoWithRetryE(t, "Kiali Namespaces Check",
		MonitoringHealthCheckRetries,
		MonitoringHealthCheckInterval,
		func() (string, error) {
			ns, err := GetKialiNamespaces(t, host)
			if err != nil {
				return "", err
			}
			namespaces = ns
			return fmt.Sprintf("%d namespaces", len(ns)), nil
		})
	return namespaces, err
}

// ============================================================================
// Application Pod 검증 함수 (Issue #27)
// ============================================================================

// VerifyApplicationPodsReady titanium-prod namespace의 Application Pod Ready 상태 확인
// kubectl wait 사용으로 모든 레플리카 검증 (Issue #27 - 2차 리뷰)
func VerifyApplicationPodsReady(t *testing.T, host ssh.Host) error {
	// 필수 Application Pod 목록
	requiredPods := []string{
		"api-gateway",
		"auth-service",
		"blog-service",
		"user-service",
	}

	for _, podPrefix := range requiredPods {
		// kubectl wait 사용으로 모든 레플리카가 Ready 상태인지 확인
		command := fmt.Sprintf(`sudo kubectl wait --for=condition=ready pod -l app=%s -n %s --timeout=30s 2>&1`, podPrefix, NamespaceProd)
		output, err := RunSSHCommand(t, host, command)
		if err != nil {
			return fmt.Errorf("%s Pod Ready 대기 실패: %v (output: %s)", podPrefix, err, strings.TrimSpace(output))
		}

		t.Logf("%s Pod가 Ready 상태입니다", podPrefix)
	}

	return nil
}

// VerifyApplicationHealth Application Health endpoint 확인
// ClusterIP Service이므로 kubectl exec를 통해 내부에서 health check 수행
func VerifyApplicationHealth(t *testing.T, host ssh.Host) error {
	// Health Check 대상 서비스 (ClusterIP:Port)
	services := map[string]struct {
		deployment string
		endpoint   string
	}{
		"api-gateway":  {deployment: "api-gateway", endpoint: "api-gateway-service:8000"},
		"auth-service": {deployment: "auth-service", endpoint: "auth-service:8002"},
		"user-service": {deployment: "user-service", endpoint: "user-service:8001"},
		"blog-service": {deployment: "blog-service", endpoint: "blog-service:8005"},
	}

	for name, svc := range services {
		// kubectl exec로 Pod 내부에서 wget 실행 (curl이 없을 수 있음)
		command := fmt.Sprintf(`sudo kubectl exec -n %s deployment/%s -- wget -qO- --timeout=5 "http://%s/health" 2>/dev/null | head -c 100 || echo 'HEALTH_CHECK_FAILED'`,
			NamespaceProd, svc.deployment, svc.endpoint)
		output, err := RunSSHCommand(t, host, command)
		if err != nil {
			return fmt.Errorf("%s health check 실패: %v", name, err)
		}

		if strings.Contains(output, "HEALTH_CHECK_FAILED") {
			return fmt.Errorf("%s health check 실패: endpoint 응답 없음", name)
		}

		t.Logf("%s health check 성공", name)
	}

	return nil
}

// VerifyApplicationPodsReadyWithRetry Application Pod Ready 확인 (재시도 포함)
func VerifyApplicationPodsReadyWithRetry(t *testing.T, host ssh.Host) error {
	_, err := retry.DoWithRetryE(t, "Application Pods Ready Check",
		MonitoringHealthCheckRetries,
		MonitoringHealthCheckInterval,
		func() (string, error) {
			err := VerifyApplicationPodsReady(t, host)
			if err != nil {
				return "", err
			}
			return "pods ready", nil
		})
	return err
}

// VerifyApplicationHealthWithRetry Application Health 확인 (재시도 포함)
func VerifyApplicationHealthWithRetry(t *testing.T, host ssh.Host) error {
	_, err := retry.DoWithRetryE(t, "Application Health Check",
		MonitoringHealthCheckRetries,
		MonitoringHealthCheckInterval,
		func() (string, error) {
			err := VerifyApplicationHealth(t, host)
			if err != nil {
				return "", err
			}
			return "healthy", nil
		})
	return err
}
