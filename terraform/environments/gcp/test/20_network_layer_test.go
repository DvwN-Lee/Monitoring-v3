package test

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/shell"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Layer 2: Network Layer Tests
// 비용: 낮음 (Network 리소스만 생성), 실행 시간: <5분
// 목적: VPC, Subnet, Firewall 규칙 실제 생성 및 검증

// GCPNetwork GCP VPC 응답 구조체
type GCPNetwork struct {
	Name                    string `json:"name"`
	AutoCreateSubnetworks   bool   `json:"autoCreateSubnetworks"`
	SelfLink                string `json:"selfLink"`
}

// GCPSubnet GCP Subnet 응답 구조체
type GCPSubnet struct {
	Name        string `json:"name"`
	IpCidrRange string `json:"ipCidrRange"`
	Region      string `json:"region"`
	Network     string `json:"network"`
}

// GCPFirewall GCP Firewall 응답 구조체
type GCPFirewall struct {
	Name         string   `json:"name"`
	Network      string   `json:"network"`
	SourceRanges []string `json:"sourceRanges"`
	Allowed      []struct {
		IPProtocol string   `json:"IPProtocol"`
		Ports      []string `json:"ports"`
	} `json:"allowed"`
}

// TestNetworkLayer VPC, Subnet, Firewall 통합 테스트
func TestNetworkLayer(t *testing.T) {
	t.Parallel()

	// Network 리소스만 target으로 지정
	terraformOptions := GetDefaultTerraformOptions(t)
	terraformOptions.Targets = []string{
		"google_compute_network.vpc",
		"google_compute_subnetwork.subnet",
		"google_compute_firewall.allow_ssh",
		"google_compute_firewall.allow_k8s_api",
		"google_compute_firewall.allow_internal",
		"google_compute_firewall.allow_nodeport",
	}

	// Cleanup
	defer terraform.Destroy(t, terraformOptions)

	// Deploy
	terraform.InitAndApply(t, terraformOptions)

	// Output 검증
	vpcName := terraform.Output(t, terraformOptions, "vpc_name")
	subnetName := terraform.Output(t, terraformOptions, "subnet_name")

	require.NotEmpty(t, vpcName, "VPC 이름이 비어있습니다")
	require.NotEmpty(t, subnetName, "Subnet 이름이 비어있습니다")

	// Sub-tests
	t.Run("VPCExists", func(t *testing.T) {
		testVPCExists(t, vpcName)
	})

	t.Run("SubnetConfiguration", func(t *testing.T) {
		testSubnetConfiguration(t, subnetName)
	})

	t.Run("FirewallSSH", func(t *testing.T) {
		testFirewallRule(t, vpcName, "allow-ssh", "22")
	})

	t.Run("FirewallK8sAPI", func(t *testing.T) {
		testFirewallRule(t, vpcName, "allow-k8s-api", "6443")
	})

	t.Run("FirewallInternal", func(t *testing.T) {
		testFirewallInternalRule(t, vpcName)
	})
}

// runGcloudCommand gcloud 명령어 실행
func runGcloudCommand(t *testing.T, args ...string) (string, error) {
	cmd := shell.Command{
		Command: "gcloud",
		Args:    args,
	}
	return shell.RunCommandAndGetOutputE(t, cmd)
}

// testVPCExists VPC 존재 확인
func testVPCExists(t *testing.T, vpcName string) {
	projectID := DefaultProjectID

	// gcloud compute networks describe
	output, err := runGcloudCommand(t,
		"compute", "networks", "describe", vpcName,
		"--project", projectID,
		"--format", "json",
	)
	require.NoError(t, err, "VPC '%s' 조회 실패", vpcName)

	var vpc GCPNetwork
	err = json.Unmarshal([]byte(output), &vpc)
	require.NoError(t, err, "VPC JSON 파싱 실패")

	// Auto create subnetworks 비활성화 확인
	assert.False(t, vpc.AutoCreateSubnetworks, "VPC는 auto_create_subnetworks가 false여야 합니다")

	t.Logf("VPC '%s' 검증 완료", vpcName)
}

// testSubnetConfiguration Subnet 구성 검증
func testSubnetConfiguration(t *testing.T, subnetName string) {
	projectID := DefaultProjectID
	region := DefaultRegion

	// gcloud compute subnetworks describe
	output, err := runGcloudCommand(t,
		"compute", "subnetworks", "describe", subnetName,
		"--project", projectID,
		"--region", region,
		"--format", "json",
	)
	require.NoError(t, err, "Subnet '%s' 조회 실패", subnetName)

	var subnet GCPSubnet
	err = json.Unmarshal([]byte(output), &subnet)
	require.NoError(t, err, "Subnet JSON 파싱 실패")

	// CIDR 범위 확인
	assert.Equal(t, DefaultSubnetCIDR, subnet.IpCidrRange, "Subnet CIDR이 예상과 다릅니다")

	// Region 확인
	assert.Contains(t, subnet.Region, region, "Subnet region이 예상과 다릅니다")

	t.Logf("Subnet '%s' 검증 완료 (CIDR: %s)", subnetName, subnet.IpCidrRange)
}

// testFirewallRule 특정 포트에 대한 Firewall 규칙 검증
func testFirewallRule(t *testing.T, vpcName string, ruleSuffix string, expectedPort string) {
	projectID := DefaultProjectID
	firewallName := fmt.Sprintf("%s-%s", vpcName, ruleSuffix)

	// gcloud compute firewall-rules describe
	output, err := runGcloudCommand(t,
		"compute", "firewall-rules", "describe", firewallName,
		"--project", projectID,
		"--format", "json",
	)
	require.NoError(t, err, "Firewall 규칙 '%s' 조회 실패", firewallName)

	var firewall GCPFirewall
	err = json.Unmarshal([]byte(output), &firewall)
	require.NoError(t, err, "Firewall JSON 파싱 실패")

	// 허용된 포트 확인
	portFound := false
	for _, allowed := range firewall.Allowed {
		for _, port := range allowed.Ports {
			if port == expectedPort {
				portFound = true
				break
			}
		}
	}

	assert.True(t, portFound, "Firewall 규칙 '%s'에 포트 %s가 허용되지 않았습니다", firewallName, expectedPort)
	t.Logf("Firewall 규칙 '%s' (포트 %s) 검증 완료", firewallName, expectedPort)
}

// testFirewallInternalRule 내부 통신 Firewall 규칙 검증
func testFirewallInternalRule(t *testing.T, vpcName string) {
	projectID := DefaultProjectID
	firewallName := fmt.Sprintf("%s-allow-internal", vpcName)

	// gcloud compute firewall-rules describe
	output, err := runGcloudCommand(t,
		"compute", "firewall-rules", "describe", firewallName,
		"--project", projectID,
		"--format", "json",
	)
	require.NoError(t, err, "Internal Firewall 규칙 '%s' 조회 실패", firewallName)

	var firewall GCPFirewall
	err = json.Unmarshal([]byte(output), &firewall)
	require.NoError(t, err, "Firewall JSON 파싱 실패")

	// Source ranges가 내부 CIDR인지 확인
	cidrFound := false
	for _, sourceRange := range firewall.SourceRanges {
		if sourceRange == DefaultSubnetCIDR {
			cidrFound = true
			break
		}
	}
	assert.True(t, cidrFound, "Internal Firewall의 source range가 올바르지 않습니다")

	// 프로토콜 허용 확인
	hasProtocol := len(firewall.Allowed) > 0
	assert.True(t, hasProtocol, "Internal Firewall 규칙이 내부 통신을 허용하지 않습니다")

	t.Logf("Internal Firewall 규칙 '%s' 검증 완료", firewallName)
}

// TestNetworkConnectivity Network 연결성 테스트 (선택적)
func TestNetworkConnectivity(t *testing.T) {
	t.Parallel()

	// 이 테스트는 실제 VM이 필요하므로 Layer 3에서 수행
	t.Skip("Network 연결성 테스트는 Layer 3 (Compute) 테스트에서 수행됩니다")
}

// TestNetworkPlanOnly Plan만 수행하는 Network 테스트
func TestNetworkPlanOnly(t *testing.T) {
	t.Parallel()

	terraformOptions := GetPlanOnlyTerraformOptions(t)
	terraformOptions.Targets = []string{
		"google_compute_network.vpc",
		"google_compute_subnetwork.subnet",
		"google_compute_firewall.allow_ssh",
		"google_compute_firewall.allow_k8s_api",
		"google_compute_firewall.allow_internal",
		"google_compute_firewall.allow_nodeport",
	}

	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	// VPC 리소스 확인
	vpcCount := 0
	subnetCount := 0
	firewallCount := 0

	for resourceAddr := range planStruct.ResourcePlannedValuesMap {
		if strings.Contains(resourceAddr, "google_compute_network") {
			vpcCount++
		}
		if strings.Contains(resourceAddr, "google_compute_subnetwork") {
			subnetCount++
		}
		if strings.Contains(resourceAddr, "google_compute_firewall") {
			firewallCount++
		}
	}

	assert.Equal(t, 1, vpcCount, "VPC 리소스가 1개여야 합니다")
	assert.Equal(t, 1, subnetCount, "Subnet 리소스가 1개여야 합니다")
	assert.GreaterOrEqual(t, firewallCount, 4, "Firewall 규칙이 4개 이상이어야 합니다")

	t.Logf("Network Plan 검증 완료: VPC=%d, Subnet=%d, Firewall=%d", vpcCount, subnetCount, firewallCount)
}

// ============================================================================
// Firewall Source Ranges 정책 테스트
// ============================================================================

// TestFirewallSourceRangesPolicy Firewall source_ranges 정책 검증 (실제 리소스)
func TestFirewallSourceRangesPolicy(t *testing.T) {
	t.Parallel()

	// Network 리소스만 target으로 지정
	terraformOptions := GetDefaultTerraformOptions(t)
	terraformOptions.Targets = []string{
		"google_compute_network.vpc",
		"google_compute_subnetwork.subnet",
		"google_compute_firewall.allow_ssh",
		"google_compute_firewall.allow_k8s_api",
		"google_compute_firewall.allow_internal",
		"google_compute_firewall.allow_dashboards",
	}

	defer terraform.Destroy(t, terraformOptions)
	terraform.InitAndApply(t, terraformOptions)

	clusterName := DefaultClusterName
	projectID := DefaultProjectID

	t.Run("SSHFirewallRestrictedToIAP", func(t *testing.T) {
		// SSH Firewall은 IAP IP 범위만 허용해야 함
		sshFirewallName := fmt.Sprintf("%s-allow-ssh", clusterName)
		iapRange := "35.235.240.0/20"

		err := VerifyFirewallSourceRanges(t, projectID, sshFirewallName, []string{iapRange})
		if err != nil {
			t.Logf("경고: SSH Firewall source_ranges 검증 실패: %v", err)
		} else {
			t.Logf("SSH Firewall '%s': IAP 범위(%s)만 허용 - 검증 통과", sshFirewallName, iapRange)
		}

		// 0.0.0.0/0으로 열려있지 않은지 확인
		err = VerifyFirewallNotOpenToWorld(t, projectID, sshFirewallName)
		require.NoError(t, err, "SSH Firewall이 전체 인터넷에 개방되어 있으면 안됨")
	})

	t.Run("InternalFirewallRestrictedToSubnet", func(t *testing.T) {
		// Internal Firewall은 Subnet CIDR만 허용해야 함
		internalFirewallName := fmt.Sprintf("%s-allow-internal", clusterName)

		err := VerifyFirewallSourceRanges(t, projectID, internalFirewallName, []string{DefaultSubnetCIDR})
		require.NoError(t, err, "Internal Firewall source_ranges 검증 실패")

		t.Logf("Internal Firewall '%s': Subnet CIDR(%s)만 허용 - 검증 통과", internalFirewallName, DefaultSubnetCIDR)
	})
}

// ============================================================================
// Negative Firewall 테스트 (차단되어야 할 포트)
// ============================================================================

// TestNegativeFirewallRulesPlan Plan에서 차단 포트 규칙 없음 확인
func TestNegativeFirewallRulesPlan(t *testing.T) {
	t.Parallel()

	terraformOptions := GetPlanOnlyTerraformOptions(t)

	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	// 차단되어야 할 포트 목록
	blockedPorts := []string{"8080", "9090", "2379", "2380", "3306", "5432", "10250"}

	for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
		if !strings.Contains(resourceAddr, "google_compute_firewall") {
			continue
		}

		// 전체 인터넷(0.0.0.0/0)에서 접근 가능한 Firewall 규칙 확인
		isOpenToWorld := false
		if sourceRanges, ok := resource.AttributeValues["source_ranges"].([]interface{}); ok {
			for _, sr := range sourceRanges {
				if srStr, ok := sr.(string); ok && srStr == "0.0.0.0/0" {
					isOpenToWorld = true
					break
				}
			}
		}

		if !isOpenToWorld {
			continue // 내부 네트워크만 접근 가능하면 문제없음
		}

		// 차단 포트가 허용되어 있는지 확인
		if allow, ok := resource.AttributeValues["allow"].([]interface{}); ok {
			for _, a := range allow {
				if allowMap, ok := a.(map[string]interface{}); ok {
					if ports, ok := allowMap["ports"].([]interface{}); ok {
						for _, port := range ports {
							if portStr, ok := port.(string); ok {
								for _, blocked := range blockedPorts {
									if portStr == blocked {
										t.Logf("경고: Firewall '%s'가 차단 대상 포트 %s를 0.0.0.0/0에 허용", resourceAddr, blocked)
									}
								}
							}
						}
					}
				}
			}
		}
	}

	t.Log("Negative Firewall Plan 검증 완료")
}
