package test

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/retry"
	"github.com/gruntwork-io/terratest/modules/shell"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Layer 3: Compute and K3s Bootstrap Tests
// 비용: 중간 (Compute 리소스 생성), 실행 시간: 10-15분
// 목적: VM 생성, SSH 접속, K3s 설치 및 클러스터 상태 검증

// GCPInstance GCP Compute Instance 응답 구조체
type GCPInstance struct {
	Name        string `json:"name"`
	MachineType string `json:"machineType"`
	Status      string `json:"status"`
	Zone        string `json:"zone"`
	Disks       []struct {
		Boot       bool   `json:"boot"`
		DiskSizeGb string `json:"diskSizeGb"`
	} `json:"disks"`
	Scheduling struct {
		Preemptible       bool   `json:"preemptible"`
		ProvisioningModel string `json:"provisioningModel"`
	} `json:"scheduling"`
}

// TestComputeAndK3s Compute 인스턴스 및 K3s 클러스터 통합 테스트
// 격리된 환경에서 실행되어 병렬 테스트에 안전함
func TestComputeAndK3s(t *testing.T) {
	t.Parallel()

	// 격리된 Terraform 옵션 사용 (임시 디렉터리 + 랜덤 클러스터 이름)
	terraformOptions, clusterName := GetIsolatedTerraformOptions(t)

	// Cleanup
	defer terraform.Destroy(t, terraformOptions)

	// Deploy
	terraform.InitAndApply(t, terraformOptions)

	// Output 검증 (실제 outputs.tf에 정의된 이름)
	masterPublicIP := terraform.Output(t, terraformOptions, "master_external_ip")
	masterPrivateIP := terraform.Output(t, terraformOptions, "master_internal_ip")

	require.NotEmpty(t, masterPublicIP, "Master public IP가 비어있습니다")
	require.NotEmpty(t, masterPrivateIP, "Master private IP가 비어있습니다")
	require.NotEmpty(t, clusterName, "Cluster 이름이 비어있습니다")

	t.Logf("Master Public IP: %s", masterPublicIP)
	t.Logf("Master Private IP: %s", masterPrivateIP)
	t.Logf("Cluster Name: %s", clusterName)

	// terraformOptions에서 project_id, zone 추출 (Worker 테스트에서 사용)
	projectID := terraformOptions.Vars["project_id"].(string)
	zone := terraformOptions.Vars["zone"].(string)

	// Sub-tests
	t.Run("MasterInstanceSpec", func(t *testing.T) {
		testInstanceSpec(t, clusterName+"-master", DefaultMasterMachineType, DefaultMasterDiskSize)
	})

	t.Run("WorkerInstanceSpec", func(t *testing.T) {
		// MIG에서 생성된 Worker 인스턴스 동적 조회
		workerNames, err := GetWorkerInstanceNamesWithRetry(t, clusterName, projectID, zone, DefaultWorkerCount)
		require.NoError(t, err, "Worker 인스턴스 목록 조회 실패")
		require.Len(t, workerNames, DefaultWorkerCount, "Worker 인스턴스 개수 불일치")

		for _, workerName := range workerNames {
			t.Run(workerName, func(t *testing.T) {
				testInstanceSpec(t, workerName, DefaultWorkerMachineType, DefaultWorkerDiskSize)
			})
		}
	})

	// Spot Instance 검증 (Worker만 Spot, UseSpotForWorkers=true일 때만 검증)
	t.Run("WorkerSpotInstance", func(t *testing.T) {
		if !UseSpotForWorkers {
			t.Skip("UseSpotForWorkers=false이므로 Spot 검증 생략")
		}
		// MIG에서 생성된 Worker 인스턴스 동적 조회
		workerNames, err := GetWorkerInstanceNames(t, clusterName, projectID, zone)
		require.NoError(t, err, "Worker 인스턴스 목록 조회 실패")

		for _, workerName := range workerNames {
			t.Run(workerName, func(t *testing.T) {
				testSpotInstanceConfig(t, workerName, projectID, zone)
			})
		}
	})

	t.Run("SSHConnectivity", func(t *testing.T) {
		testSSHConnectivity(t, masterPublicIP)
	})

	t.Run("K3sServerStatus", func(t *testing.T) {
		testK3sServiceStatus(t, masterPublicIP, "k3s")
	})

	// 개선된 Node Ready 검증 (status=True 명시적 확인)
	t.Run("K3sNodesReadyImproved", func(t *testing.T) {
		privateKeyPath, _ := GetSSHKeyPairPath()
		host := CreateSSHHost(t, masterPublicIP, privateKeyPath)
		err := WaitForK3sNodesReady(t, host, 1+DefaultWorkerCount)
		require.NoError(t, err, "K3s 노드 Ready 상태 확인 실패")
	})

	t.Run("K3sSystemPods", func(t *testing.T) {
		testK3sSystemPods(t, masterPublicIP)
	})

	// IAM 권한 검증
	t.Run("IAMLoggingPermission", func(t *testing.T) {
		privateKeyPath, _ := GetSSHKeyPairPath()
		host := CreateSSHHost(t, masterPublicIP, privateKeyPath)
		err := VerifyIAMLoggingPermission(t, host)
		if err != nil {
			t.Logf("Logging 권한 검증 (선택적): %v", err)
		} else {
			t.Log("Logging 권한 검증 성공")
		}
	})

	t.Run("IAMMonitoringPermission", func(t *testing.T) {
		privateKeyPath, _ := GetSSHKeyPairPath()
		host := CreateSSHHost(t, masterPublicIP, privateKeyPath)
		err := VerifyIAMMonitoringPermission(t, host)
		if err != nil {
			t.Logf("Monitoring 권한 검증 (선택적): %v", err)
		} else {
			t.Log("Monitoring 권한 검증 성공")
		}
	})
}

// TestComputeIdempotency 멱등성 테스트
// terraform.PlanExitCode를 사용하여 간결하게 검증
func TestComputeIdempotency(t *testing.T) {
	t.Parallel()

	// 격리된 환경 사용
	terraformOptions, clusterName := GetIsolatedTerraformOptions(t)

	// Cleanup
	defer terraform.Destroy(t, terraformOptions)

	// 첫 번째 Apply
	terraform.InitAndApply(t, terraformOptions)
	t.Logf("첫 번째 Apply 완료 (클러스터: %s)", clusterName)

	// 멱등성 검증: Plan 실행 후 변경 사항 없음 확인 (exit code 0)
	// Exit codes: 0 = no changes, 1 = error, 2 = changes present
	exitCode := terraform.PlanExitCode(t, terraformOptions)

	if exitCode == 0 {
		t.Log("멱등성 테스트 통과: 재적용 시 변경 사항 없음")
	} else if exitCode == 2 {
		// 변경 사항이 있는 경우 상세 정보 출력
		planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)
		for _, change := range planStruct.RawPlan.ResourceChanges {
			if len(change.Change.Actions) > 0 && change.Change.Actions[0] != "no-op" {
				t.Errorf("멱등성 실패: 리소스 '%s'에 변경 발생 - %v", change.Address, change.Change.Actions)
			}
		}
	} else {
		t.Fatalf("멱등성 테스트 실패: Plan 실행 오류 (exit code: %d)", exitCode)
	}
}

// runGcloudComputeCommand gcloud compute 명령어 실행
func runGcloudComputeCommand(t *testing.T, args ...string) (string, error) {
	cmd := shell.Command{
		Command: "gcloud",
		Args:    args,
	}
	return shell.RunCommandAndGetOutputE(t, cmd)
}

// testInstanceSpec 인스턴스 사양 검증
func testInstanceSpec(t *testing.T, instanceName string, expectedMachineType string, expectedDiskSize int) {
	projectID := DefaultProjectID
	zone := DefaultZone

	// gcloud compute instances describe
	output, err := runGcloudComputeCommand(t,
		"compute", "instances", "describe", instanceName,
		"--project", projectID,
		"--zone", zone,
		"--format", "json",
	)
	require.NoError(t, err, "인스턴스 '%s' 조회 실패", instanceName)

	var instance GCPInstance
	err = json.Unmarshal([]byte(output), &instance)
	require.NoError(t, err, "Instance JSON 파싱 실패")

	// Machine type 확인
	assert.Contains(t, instance.MachineType, expectedMachineType, "Machine type이 예상과 다릅니다")

	// Disk size 확인
	for _, disk := range instance.Disks {
		if disk.Boot {
			var diskSize int64
			fmt.Sscanf(disk.DiskSizeGb, "%d", &diskSize)
			assert.GreaterOrEqual(t, diskSize, int64(expectedDiskSize), "Boot disk 크기가 예상보다 작습니다")
		}
	}

	// 상태 확인
	assert.Equal(t, "RUNNING", instance.Status, "인스턴스가 RUNNING 상태가 아닙니다")

	t.Logf("인스턴스 '%s' 사양 검증 완료 (type: %s, status: %s)", instanceName, expectedMachineType, instance.Status)
}

// testSpotInstanceConfig Spot/Preemptible 인스턴스 설정 검증
// projectID, zone을 인자로 받아 동적 환경 지원
func testSpotInstanceConfig(t *testing.T, instanceName, projectID, zone string) {
	output, err := runGcloudComputeCommand(t,
		"compute", "instances", "describe", instanceName,
		"--project", projectID,
		"--zone", zone,
		"--format", "json",
	)
	require.NoError(t, err, "인스턴스 '%s' 조회 실패", instanceName)

	var instance GCPInstance
	err = json.Unmarshal([]byte(output), &instance)
	require.NoError(t, err, "Instance JSON 파싱 실패")

	// Preemptible 또는 SPOT 확인
	isSpot := instance.Scheduling.Preemptible ||
		instance.Scheduling.ProvisioningModel == "SPOT"

	assert.True(t, isSpot, "Worker 인스턴스 '%s'가 Spot/Preemptible이 아닙니다 (preemptible=%v, model=%s)",
		instanceName, instance.Scheduling.Preemptible, instance.Scheduling.ProvisioningModel)

	t.Logf("Spot 인스턴스 '%s' 검증 완료 (preemptible=%v, model=%s)",
		instanceName, instance.Scheduling.Preemptible, instance.Scheduling.ProvisioningModel)
}

// testSSHConnectivity SSH 연결 테스트
func testSSHConnectivity(t *testing.T, publicIP string) {
	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, publicIP, privateKeyPath)

	// SSH 연결 테스트
	output, err := RunSSHCommandWithRetry(t, host, "echo 'SSH connection successful'", "SSH 연결 테스트")
	require.NoError(t, err, "SSH 연결 실패")
	assert.Contains(t, output, "SSH connection successful", "SSH 명령 실행 결과가 예상과 다릅니다")

	t.Logf("SSH 연결 성공: %s", publicIP)
}

// testK3sServiceStatus K3s 서비스 상태 확인
func testK3sServiceStatus(t *testing.T, publicIP string, serviceName string) {
	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, publicIP, privateKeyPath)

	// K3s 서비스 부팅 대기
	maxRetries := 30
	sleepBetweenRetries := 10 * time.Second

	_, err := retry.DoWithRetryE(t, "K3s 서비스 대기", maxRetries, sleepBetweenRetries, func() (string, error) {
		output, err := RunSSHCommand(t, host, fmt.Sprintf("systemctl is-active %s", serviceName))
		if err != nil {
			return "", fmt.Errorf("서비스 상태 확인 실패: %v", err)
		}
		if strings.TrimSpace(output) != "active" {
			return "", fmt.Errorf("서비스가 active 상태가 아닙니다: %s", output)
		}
		return output, nil
	})

	require.NoError(t, err, "K3s 서비스가 active 상태가 아닙니다")
	t.Logf("K3s 서비스 '%s' 상태: active", serviceName)
}

// testK3sSystemPods K3s 시스템 Pod 상태 확인
func testK3sSystemPods(t *testing.T, publicIP string) {
	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, publicIP, privateKeyPath)

	// 시스템 Pod Ready 대기
	maxRetries := 30
	sleepBetweenRetries := 10 * time.Second

	requiredPods := []string{
		"coredns",
		"local-path-provisioner",
		"metrics-server",
	}

	for _, podPrefix := range requiredPods {
		_, err := retry.DoWithRetryE(t, fmt.Sprintf("%s Pod 대기", podPrefix), maxRetries, sleepBetweenRetries, func() (string, error) {
			output, err := RunSSHCommand(t, host, fmt.Sprintf("sudo kubectl get pods -n kube-system --no-headers | grep '%s' | grep -c 'Running'", podPrefix))
			if err != nil {
				return "", fmt.Errorf("%s Pod 상태 확인 실패: %v", podPrefix, err)
			}

			runningCount := 0
			fmt.Sscanf(strings.TrimSpace(output), "%d", &runningCount)

			if runningCount < 1 {
				return "", fmt.Errorf("%s Pod가 Running 상태가 아닙니다", podPrefix)
			}

			return output, nil
		})

		require.NoError(t, err, "%s Pod가 Running 상태가 아닙니다", podPrefix)
		t.Logf("시스템 Pod '%s' 상태: Running", podPrefix)
	}

	// 전체 시스템 Pod 목록 출력
	output, _ := RunSSHCommand(t, host, "sudo kubectl get pods -n kube-system")
	t.Logf("K3s 시스템 Pod:\n%s", output)
}

// TestComputePlanOnly Plan만 수행하는 Compute 테스트 (격리된 환경)
func TestComputePlanOnly(t *testing.T) {
	t.Parallel()

	terraformOptions, clusterName := GetIsolatedPlanOnlyOptions(t)

	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	// Compute 리소스 확인
	instanceCount := 0
	addressCount := 0

	for resourceAddr := range planStruct.ResourcePlannedValuesMap {
		if strings.Contains(resourceAddr, "google_compute_instance") {
			instanceCount++
		}
		if strings.Contains(resourceAddr, "google_compute_address") {
			addressCount++
		}
	}

	expectedInstances := 1 + DefaultWorkerCount // master + workers
	assert.Equal(t, expectedInstances, instanceCount, "Instance 리소스 개수가 예상과 다릅니다")
	assert.GreaterOrEqual(t, addressCount, 1, "Static IP address가 최소 1개 이상이어야 합니다")

	t.Logf("Compute Plan 검증 완료 (클러스터: %s): Instances=%d, Addresses=%d", clusterName, instanceCount, addressCount)
}

// TestSpotInstancePreemption Spot 인스턴스 Preemption 테스트 (선택적)
func TestSpotInstancePreemption(t *testing.T) {
	t.Skip("Spot 인스턴스 Preemption 테스트는 시간이 오래 걸려 기본적으로 skip됩니다")
}

// ============================================================================
// Negative Firewall Connectivity 테스트 (실제 포트 차단 검증)
// ============================================================================

// TestNegativeFirewallConnectivity 차단 포트 연결 거부 검증
func TestNegativeFirewallConnectivity(t *testing.T) {
	t.Parallel()

	// 격리된 환경 사용
	terraformOptions, clusterName := GetIsolatedTerraformOptions(t)

	defer terraform.Destroy(t, terraformOptions)
	terraform.InitAndApply(t, terraformOptions)

	masterPublicIP := terraform.Output(t, terraformOptions, "master_external_ip")
	require.NotEmpty(t, masterPublicIP, "Master public IP가 비어있습니다")

	t.Logf("Negative Firewall 테스트 시작 (클러스터: %s, IP: %s)", clusterName, masterPublicIP)

	// 차단되어야 할 포트 테스트
	blockedPortsToTest := []int{
		8080,  // 일반 HTTP 대체
		9090,  // Prometheus 기본
		2379,  // etcd client
		3306,  // MySQL
		5432,  // PostgreSQL
		10250, // Kubelet API
	}

	timeout := 5 * time.Second

	for _, port := range blockedPortsToTest {
		t.Run(fmt.Sprintf("Port_%d_Blocked", port), func(t *testing.T) {
			isBlocked := TestPortBlocked(t, masterPublicIP, port, timeout)
			if isBlocked {
				t.Logf("포트 %d: 정상적으로 차단됨", port)
			} else {
				t.Errorf("보안 경고: 포트 %d가 외부에서 접근 가능", port)
			}
		})
	}

	// 허용된 포트는 접근 가능해야 함
	allowedPorts := []int{
		22,   // SSH (IAP 경유하지 않으면 차단될 수 있음)
		6443, // K8s API
	}

	for _, port := range allowedPorts {
		t.Run(fmt.Sprintf("Port_%d_Allowed", port), func(t *testing.T) {
			isBlocked := TestPortBlocked(t, masterPublicIP, port, timeout)
			if !isBlocked {
				t.Logf("포트 %d: 정상적으로 접근 가능", port)
			} else {
				// 22번 포트는 IAP 경유 시에만 접근 가능하므로 경고만 출력
				if port == 22 {
					t.Logf("경고: 포트 %d - IAP 경유하지 않아 직접 접근 차단됨 (정상)", port)
				} else {
					t.Logf("경고: 포트 %d가 차단됨 - 네트워크 설정 확인 필요", port)
				}
			}
		})
	}
}

// ============================================================================
// Node Scale-up 테스트
// ============================================================================

// TestNodeScaleUp Worker 노드 Scale-up 테스트
func TestNodeScaleUp(t *testing.T) {
	t.Parallel()

	// 격리된 환경 사용
	terraformOptions, clusterName := GetIsolatedTerraformOptions(t)

	defer terraform.Destroy(t, terraformOptions)

	// Step 1: worker_count=1로 초기 배포
	terraformOptions.Vars["worker_count"] = 1
	terraform.InitAndApply(t, terraformOptions)

	masterPublicIP := terraform.Output(t, terraformOptions, "master_external_ip")
	require.NotEmpty(t, masterPublicIP, "Master public IP가 비어있습니다")

	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, masterPublicIP, privateKeyPath)

	// 초기 노드 목록 기록
	initialNodes, err := GetK3sNodeNames(t, host)
	require.NoError(t, err, "초기 노드 목록 조회 실패")
	t.Logf("초기 노드 목록 (%d개): %v", len(initialNodes), initialNodes)

	expectedInitialCount := 2 // master(1) + worker(1)
	require.Equal(t, expectedInitialCount, len(initialNodes), "초기 노드 수가 예상과 다릅니다")

	// Step 2: worker_count=2로 Scale-up
	terraformOptions.Vars["worker_count"] = 2
	terraform.Apply(t, terraformOptions)

	t.Log("Scale-up 완료, 노드 조인 대기...")

	// 새 노드 조인 대기
	expectedFinalCount := 3 // master(1) + worker(2)
	err = WaitForK3sNodesReady(t, host, expectedFinalCount)
	require.NoError(t, err, "Scale-up 후 노드 Ready 상태 확인 실패")

	// 최종 노드 목록 조회
	finalNodes, err := GetK3sNodeNames(t, host)
	require.NoError(t, err, "최종 노드 목록 조회 실패")
	t.Logf("최종 노드 목록 (%d개): %v", len(finalNodes), finalNodes)

	// Step 3: 기존 노드가 유지되는지 확인
	for _, initialNode := range initialNodes {
		found := false
		for _, finalNode := range finalNodes {
			if initialNode == finalNode {
				found = true
				break
			}
		}
		require.True(t, found, "기존 노드 '%s'가 Scale-up 후 사라졌습니다", initialNode)
	}

	// Step 4: 새 노드가 추가되었는지 확인
	newNodeCount := len(finalNodes) - len(initialNodes)
	assert.Equal(t, 1, newNodeCount, "새로 추가된 노드 수가 1개여야 합니다")

	// Step 5: 모든 노드가 Ready 상태인지 확인
	for _, nodeName := range finalNodes {
		isReady, err := VerifyNodeReady(t, host, nodeName)
		require.NoError(t, err, "노드 '%s' 상태 확인 실패", nodeName)
		assert.True(t, isReady, "노드 '%s'가 Ready 상태가 아닙니다", nodeName)
	}

	t.Logf("Node Scale-up 테스트 통과 (클러스터: %s): %d -> %d 노드", clusterName, expectedInitialCount, expectedFinalCount)
}
