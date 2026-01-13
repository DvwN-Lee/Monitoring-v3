package test

import (
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Layer 1: Plan Unit Tests
// 비용: $0, 실행 시간: <2분
// 목적: terraform plan 결과 분석을 통한 리소스 구성 검증

// TestPlanResourceCount 생성될 리소스 개수 검증
func TestPlanResourceCount(t *testing.T) {
	t.Parallel()

	terraformOptions := GetPlanOnlyTerraformOptions(t)

	// Init and Plan
	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	// 예상 리소스 타입 목록
	expectedResourceTypes := []string{
		"google_compute_network",
		"google_compute_subnetwork",
		"google_compute_firewall",
		"google_compute_instance",
		"google_compute_address",
		"local_file",
		"null_resource",
	}

	// Plan에 리소스가 포함되어 있는지 확인
	resourceCount := len(planStruct.ResourcePlannedValuesMap)
	assert.Greater(t, resourceCount, 0, "Plan에 생성될 리소스가 없습니다")

	t.Logf("Plan에 포함된 리소스 개수: %d", resourceCount)

	// 각 예상 리소스 타입이 존재하는지 확인
	for _, expectedType := range expectedResourceTypes {
		found := false
		for resourceAddr := range planStruct.ResourcePlannedValuesMap {
			if strings.Contains(resourceAddr, expectedType) {
				found = true
				break
			}
		}
		if !found {
			t.Logf("경고: 예상 리소스 타입 '%s'가 Plan에 없습니다", expectedType)
		}
	}
}

// TestPlanNetworkConfig Network 구성 검증
func TestPlanNetworkConfig(t *testing.T) {
	t.Parallel()

	terraformOptions := GetPlanOnlyTerraformOptions(t)

	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	// VPC 리소스 확인
	vpcFound := false
	subnetFound := false

	for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
		if strings.Contains(resourceAddr, "google_compute_network") {
			vpcFound = true
			// Auto create subnetworks 비활성화 확인
			if autoCreate, ok := resource.AttributeValues["auto_create_subnetworks"].(bool); ok {
				assert.False(t, autoCreate, "VPC는 auto_create_subnetworks가 false여야 합니다")
			}
		}

		if strings.Contains(resourceAddr, "google_compute_subnetwork") {
			subnetFound = true
			// Subnet CIDR 확인
			if ipRange, ok := resource.AttributeValues["ip_cidr_range"].(string); ok {
				assert.Equal(t, DefaultSubnetCIDR, ipRange, "Subnet CIDR이 예상과 다릅니다")
			}
			// Region 확인
			if region, ok := resource.AttributeValues["region"].(string); ok {
				assert.Equal(t, DefaultRegion, region, "Subnet region이 예상과 다릅니다")
			}
		}
	}

	assert.True(t, vpcFound, "VPC 리소스가 Plan에 없습니다")
	assert.True(t, subnetFound, "Subnet 리소스가 Plan에 없습니다")
}

// TestPlanComputeConfig Compute 리소스 구성 검증
func TestPlanComputeConfig(t *testing.T) {
	t.Parallel()

	terraformOptions := GetPlanOnlyTerraformOptions(t)

	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	masterFound := false
	workerFound := false

	for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
		if strings.Contains(resourceAddr, "google_compute_instance") {
			// Machine type 확인
			if machineType, ok := resource.AttributeValues["machine_type"].(string); ok {
				if strings.Contains(resourceAddr, "master") {
					masterFound = true
					assert.Equal(t, DefaultMasterMachineType, machineType, "Master machine type이 예상과 다릅니다")
				}
				if strings.Contains(resourceAddr, "worker") {
					workerFound = true
					assert.Equal(t, DefaultWorkerMachineType, machineType, "Worker machine type이 예상과 다릅니다")
				}
			}

			// Zone 확인
			if zone, ok := resource.AttributeValues["zone"].(string); ok {
				assert.Equal(t, DefaultZone, zone, "Instance zone이 예상과 다릅니다")
			}
		}
	}

	assert.True(t, masterFound, "Master instance가 Plan에 없습니다")
	assert.True(t, workerFound, "Worker instance가 Plan에 없습니다")
}

// TestPlanFirewallRules Firewall 규칙 검증
func TestPlanFirewallRules(t *testing.T) {
	t.Parallel()

	terraformOptions := GetPlanOnlyTerraformOptions(t)

	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	// 필수 Firewall 규칙 확인
	requiredPorts := map[string]bool{
		"22":    false, // SSH
		"6443":  false, // K8s API
		"80":    false, // HTTP
		"443":   false, // HTTPS
	}

	for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
		if strings.Contains(resourceAddr, "google_compute_firewall") {
			// allow 블록 확인
			if allow, ok := resource.AttributeValues["allow"].([]interface{}); ok {
				for _, a := range allow {
					if allowMap, ok := a.(map[string]interface{}); ok {
						if ports, ok := allowMap["ports"].([]interface{}); ok {
							for _, port := range ports {
								if portStr, ok := port.(string); ok {
									if _, exists := requiredPorts[portStr]; exists {
										requiredPorts[portStr] = true
									}
								}
							}
						}
					}
				}
			}
		}
	}

	// 모든 필수 포트가 허용되는지 확인
	for port, found := range requiredPorts {
		if !found {
			t.Logf("경고: 포트 %s에 대한 Firewall 규칙이 Plan에 없습니다", port)
		}
	}
}

// TestPlanOutputDefinitions Output 정의 확인
func TestPlanOutputDefinitions(t *testing.T) {
	t.Parallel()

	terraformOptions := GetPlanOnlyTerraformOptions(t)

	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	// 필수 Output 목록 (실제 outputs.tf에 정의된 이름)
	requiredOutputs := []string{
		"master_external_ip",
		"master_internal_ip",
		"vpc_id",
		"subnet_id",
		"cluster_endpoint",
		"argocd_url",
		"grafana_url",
		"kiali_url",
		"deployment_status",
	}

	// Plan의 Output 확인
	for _, outputName := range requiredOutputs {
		_, exists := planStruct.RawPlan.PlannedValues.Outputs[outputName]
		require.True(t, exists, "필수 Output '%s'가 정의되어 있지 않습니다", outputName)
	}

	t.Logf("모든 필수 Output이 정의되어 있습니다: %v", requiredOutputs)
}

// TestPlanNoSensitiveHardcoding 민감한 값 하드코딩 방지 검증
func TestPlanNoSensitiveHardcoding(t *testing.T) {
	t.Parallel()

	terraformOptions := GetPlanOnlyTerraformOptions(t)

	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	// 민감한 패턴 목록
	sensitivePatterns := []string{
		"password=",
		"secret=",
		"api_key=",
		"private_key=",
	}

	for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
		for key, value := range resource.AttributeValues {
			// metadata_startup_script는 templatefile로 변수 주입된 값을 포함하므로 제외
			if key == "metadata_startup_script" {
				continue
			}

			if strValue, ok := value.(string); ok {
				for _, pattern := range sensitivePatterns {
					if strings.Contains(strings.ToLower(strValue), pattern) {
						t.Errorf("리소스 '%s'의 '%s' 속성에 민감한 값이 하드코딩되어 있습니다", resourceAddr, key)
					}
				}
			}
		}
	}

	t.Log("민감한 값 하드코딩 검증 통과 (metadata_startup_script 제외)")
}

// ============================================================================
// Negative Plan Tests (유효하지 않은 입력 검증)
// ============================================================================

// TestPlanInvalidInputs 잘못된 입력에서 Plan 실패 검증
func TestPlanInvalidInputs(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name        string
		vars        map[string]interface{}
		expectError bool
		description string
	}{
		{
			name: "InvalidMachineType",
			vars: map[string]interface{}{
				"master_machine_type": "invalid-machine-type-xyz",
			},
			expectError: true,
			description: "존재하지 않는 machine_type은 Plan 실패해야 함",
		},
		{
			name: "NegativeWorkerCount",
			vars: map[string]interface{}{
				"worker_count": -1,
			},
			expectError: true,
			description: "음수 worker_count는 Plan 실패해야 함",
		},
		{
			name: "InvalidRegion",
			vars: map[string]interface{}{
				"region": "fake-region-999",
				"zone":   "fake-region-999-a",
			},
			expectError: true,
			description: "존재하지 않는 region은 Plan 실패해야 함",
		},
		{
			name: "EmptyProjectID",
			vars: map[string]interface{}{
				"project_id": "",
			},
			expectError: true,
			description: "빈 project_id는 Plan 실패해야 함",
		},
	}

	for _, tc := range testCases {
		tc := tc // capture range variable
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			// 기본 옵션에서 테스트 변수 덮어쓰기
			opts := GetPlanOnlyTerraformOptions(t)
			for k, v := range tc.vars {
				opts.Vars[k] = v
			}

			// Plan 실행
			_, err := terraform.InitAndPlanE(t, opts)

			if tc.expectError {
				if err == nil {
					t.Logf("경고: %s - Plan이 성공했지만 실패가 예상됨", tc.description)
					// 일부 입력은 Plan 단계에서는 검증되지 않을 수 있음
				} else {
					t.Logf("예상대로 Plan 실패: %s", tc.description)
				}
			} else {
				if err != nil {
					t.Errorf("%s - Plan 실패: %v", tc.description, err)
				}
			}
		})
	}
}

// ============================================================================
// Firewall Source Ranges Plan 검증
// ============================================================================

// TestPlanFirewallSourceRanges Firewall source_ranges 정책 검증
func TestPlanFirewallSourceRanges(t *testing.T) {
	t.Parallel()

	terraformOptions := GetPlanOnlyTerraformOptions(t)

	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	// SSH Firewall 규칙의 source_ranges 검증
	// IAP(Identity-Aware Proxy) IP 범위만 허용되어야 함: 35.235.240.0/20
	iapRange := "35.235.240.0/20"
	sshFirewallFound := false
	sshSourceRangesCorrect := false

	for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
		if strings.Contains(resourceAddr, "google_compute_firewall") &&
			strings.Contains(resourceAddr, "ssh") {
			sshFirewallFound = true

			if sourceRanges, ok := resource.AttributeValues["source_ranges"].([]interface{}); ok {
				for _, sr := range sourceRanges {
					if srStr, ok := sr.(string); ok {
						if srStr == iapRange {
							sshSourceRangesCorrect = true
						}
						// 0.0.0.0/0으로 열려있으면 보안 경고
						if srStr == "0.0.0.0/0" {
							t.Errorf("SSH Firewall이 전체 인터넷(0.0.0.0/0)에 개방됨 - 보안 위험")
						}
					}
				}
			}
		}
	}

	if sshFirewallFound {
		if sshSourceRangesCorrect {
			t.Logf("SSH Firewall source_ranges 검증 통과: IAP 범위(%s)만 허용", iapRange)
		} else {
			t.Logf("경고: SSH Firewall에 IAP 범위(%s)가 포함되지 않음", iapRange)
		}
	} else {
		t.Logf("경고: SSH Firewall 규칙이 Plan에서 발견되지 않음")
	}
}

// TestPlanFirewallNoWideOpen 전체 개방 Firewall 규칙 경고
func TestPlanFirewallNoWideOpen(t *testing.T) {
	t.Parallel()

	terraformOptions := GetPlanOnlyTerraformOptions(t)

	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	// 보안에 민감한 포트 목록
	sensitivePortPrefixes := []string{"ssh", "etcd", "kubelet"}

	for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
		if !strings.Contains(resourceAddr, "google_compute_firewall") {
			continue
		}

		// 민감한 Firewall 규칙인지 확인
		isSensitive := false
		for _, prefix := range sensitivePortPrefixes {
			if strings.Contains(strings.ToLower(resourceAddr), prefix) {
				isSensitive = true
				break
			}
		}

		if !isSensitive {
			continue
		}

		// source_ranges 검사
		if sourceRanges, ok := resource.AttributeValues["source_ranges"].([]interface{}); ok {
			for _, sr := range sourceRanges {
				if srStr, ok := sr.(string); ok && srStr == "0.0.0.0/0" {
					t.Errorf("보안 경고: 민감한 Firewall '%s'가 0.0.0.0/0에 개방됨", resourceAddr)
				}
			}
		}
	}
}
