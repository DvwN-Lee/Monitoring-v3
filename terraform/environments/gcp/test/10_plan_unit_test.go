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
			if strValue, ok := value.(string); ok {
				for _, pattern := range sensitivePatterns {
					if strings.Contains(strings.ToLower(strValue), pattern) {
						t.Errorf("리소스 '%s'의 '%s' 속성에 민감한 값이 하드코딩되어 있습니다", resourceAddr, key)
					}
				}
			}
		}
	}
}
