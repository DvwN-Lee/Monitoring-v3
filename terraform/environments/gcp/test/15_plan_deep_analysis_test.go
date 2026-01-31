package test

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Layer 1.5: Plan Deep Analysis Tests
// 비용: $0, 실행 시간: <3분
// 목적: terraform plan 결과에 대한 심층 정적 분석 (Resource 개수, Firewall 전수 검사, IAM, 보안 설정)

func TestPlanDeepAnalysis(t *testing.T) {
	t.Parallel()

	terraformOptions := GetPlanOnlyTerraformOptions(t)

	terraform.Init(t, terraformOptions)
	planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	// ========================================================================
	// Subtest 1: ResourceCount - 타입별 정확한 Resource 개수 검증
	// ========================================================================
	t.Run("ResourceCount", func(t *testing.T) {
		expectedCounts := map[string]int{
			"google_compute_firewall":                5,
			"google_compute_instance":                1, // Master만
			"google_compute_instance_template":       1,
			"google_compute_instance_group_manager":  1,
			"google_compute_health_check":            1,
			"google_service_account":                 1,
			"google_project_iam_member":              3,
			"google_secret_manager_secret":           7,
		}

		actualCounts := make(map[string]int)
		for resourceAddr := range planStruct.ResourcePlannedValuesMap {
			for resourceType := range expectedCounts {
				if strings.HasPrefix(resourceAddr, resourceType+".") {
					actualCounts[resourceType]++
				}
			}
		}

		for resourceType, expected := range expectedCounts {
			actual := actualCounts[resourceType]
			assert.Equal(t, expected, actual,
				"%s: 예상 %d개, 실제 %d개", resourceType, expected, actual)
		}
	})

	// ========================================================================
	// Subtest 2: FirewallTargetTags - 각 Firewall 규칙의 target_tags 정확성
	// ========================================================================
	t.Run("FirewallTargetTags", func(t *testing.T) {
		// Firewall 이름 suffix -> 예상 target_tags (정렬된 상태로 비교)
		expectedTags := map[string][]string{
			"allow-ssh":          {"k3s-node"},
			"allow-k8s-api":     {"k3s-master"},
			"allow-dashboards":  {"k3s-master", "k3s-worker"},
			"allow-health-check": {"k3s-worker"},
		}

		for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
			if !strings.Contains(resourceAddr, "google_compute_firewall") {
				continue
			}

			for suffix, expected := range expectedTags {
				if !strings.Contains(resourceAddr, suffix) {
					continue
				}

				tags, ok := resource.AttributeValues["target_tags"].([]interface{})
				require.True(t, ok, "Firewall '%s': target_tags 속성이 없습니다", suffix)

				var actual []string
				for _, tag := range tags {
					if s, ok := tag.(string); ok {
						actual = append(actual, s)
					}
				}
				sort.Strings(actual)
				sort.Strings(expected)
				assert.Equal(t, expected, actual,
					"Firewall '%s': target_tags 불일치", suffix)
			}
		}
	})

	// ========================================================================
	// Subtest 3: FirewallNoOpenToWorld - 전체 Firewall 규칙 0.0.0.0/0 전수 검사
	// ========================================================================
	t.Run("FirewallNoOpenToWorld", func(t *testing.T) {
		for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
			if !strings.Contains(resourceAddr, "google_compute_firewall") {
				continue
			}

			sourceRanges, ok := resource.AttributeValues["source_ranges"].([]interface{})
			if !ok {
				continue
			}

			for _, sr := range sourceRanges {
				if srStr, ok := sr.(string); ok {
					assert.NotEqual(t, "0.0.0.0/0", srStr,
						"Firewall '%s': 전체 인터넷(0.0.0.0/0)에 개방됨", resourceAddr)
				}
			}
		}
	})

	// ========================================================================
	// Subtest 4: FirewallInternalSourceRange - Internal Firewall의 source_ranges 검증
	// ========================================================================
	t.Run("FirewallInternalSourceRange", func(t *testing.T) {
		for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
			if !strings.Contains(resourceAddr, "google_compute_firewall") {
				continue
			}
			if !strings.Contains(resourceAddr, "internal") {
				continue
			}

			sourceRanges, ok := resource.AttributeValues["source_ranges"].([]interface{})
			require.True(t, ok, "Internal Firewall: source_ranges 속성이 없습니다")

			// Internal Firewall은 subnet CIDR만 허용
			require.Len(t, sourceRanges, 1,
				"Internal Firewall: source_ranges는 정확히 1개여야 합니다")
			assert.Equal(t, DefaultSubnetCIDR, sourceRanges[0],
				"Internal Firewall: source_ranges는 subnet CIDR(%s)이어야 합니다", DefaultSubnetCIDR)
		}
	})

	// ========================================================================
	// Subtest 5: FirewallHealthCheckSourceRange - Health check CIDR 검증
	// ========================================================================
	t.Run("FirewallHealthCheckSourceRange", func(t *testing.T) {
		for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
			if !strings.Contains(resourceAddr, "google_compute_firewall") {
				continue
			}
			if !strings.Contains(resourceAddr, "health-check") {
				continue
			}

			sourceRanges, ok := resource.AttributeValues["source_ranges"].([]interface{})
			require.True(t, ok, "Health Check Firewall: source_ranges 속성이 없습니다")

			expectedCIDRs := []string{GCPHealthCheckCidr1, GCPHealthCheckCidr2}
			var actual []string
			for _, sr := range sourceRanges {
				if s, ok := sr.(string); ok {
					actual = append(actual, s)
				}
			}
			sort.Strings(actual)
			sort.Strings(expectedCIDRs)
			assert.Equal(t, expectedCIDRs, actual,
				"Health Check Firewall: source_ranges는 GCP Health Check CIDR이어야 합니다")
		}
	})

	// ========================================================================
	// Subtest 6: FirewallPortsAccuracy - 각 Firewall 규칙의 허용 Port 정확성
	// ========================================================================
	t.Run("FirewallPortsAccuracy", func(t *testing.T) {
		// Firewall 이름 suffix -> 예상 protocol:ports
		type allowRule struct {
			protocol string
			ports    []string // 빈 슬라이스 = 전체 포트 (ICMP 등)
		}

		expectedRules := map[string][]allowRule{
			"allow-ssh": {
				{protocol: "tcp", ports: []string{"22"}},
			},
			"allow-k8s-api": {
				{protocol: "tcp", ports: []string{"6443"}},
			},
			"allow-dashboards": {
				{protocol: "tcp", ports: []string{"80", "443", "30000-32767"}},
			},
			"allow-internal": {
				{protocol: "tcp", ports: []string{"0-65535"}},
				{protocol: "udp", ports: []string{"0-65535"}},
				{protocol: "icmp", ports: nil},
			},
			"allow-health-check": {
				{protocol: "tcp", ports: []string{"10250"}},
			},
		}

		for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
			if !strings.Contains(resourceAddr, "google_compute_firewall") {
				continue
			}

			for suffix, expected := range expectedRules {
				if !strings.Contains(resourceAddr, suffix) {
					continue
				}

				allow, ok := resource.AttributeValues["allow"].([]interface{})
				require.True(t, ok, "Firewall '%s': allow 블록이 없습니다", suffix)
				assert.Len(t, allow, len(expected),
					"Firewall '%s': allow 블록 개수 불일치", suffix)

				// allow 블록에서 protocol:ports 추출
				actualMap := make(map[string][]string)
				for _, a := range allow {
					if aMap, ok := a.(map[string]interface{}); ok {
						proto := ""
						if p, ok := aMap["protocol"].(string); ok {
							proto = p
						}
						var ports []string
						if ps, ok := aMap["ports"].([]interface{}); ok {
							for _, p := range ps {
								if s, ok := p.(string); ok {
									ports = append(ports, s)
								}
							}
						}
						sort.Strings(ports)
						actualMap[proto] = ports
					}
				}

				for _, exp := range expected {
					actualPorts, exists := actualMap[exp.protocol]
					assert.True(t, exists,
						"Firewall '%s': protocol '%s' 누락", suffix, exp.protocol)
					if exp.ports != nil {
						sorted := make([]string, len(exp.ports))
						copy(sorted, exp.ports)
						sort.Strings(sorted)
						assert.Equal(t, sorted, actualPorts,
							"Firewall '%s' protocol '%s': 포트 불일치", suffix, exp.protocol)
					}
				}
			}
		}
	})

	// ========================================================================
	// Subtest 7: MasterInstanceConfig - Master Instance 보안 설정
	// ========================================================================
	t.Run("MasterInstanceConfig", func(t *testing.T) {
		for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
			if !strings.HasPrefix(resourceAddr, "google_compute_instance.") {
				continue
			}
			if !strings.Contains(resourceAddr, "master") {
				continue
			}

			// tags 검증
			if tags, ok := resource.AttributeValues["tags"].([]interface{}); ok {
				var tagStrs []string
				for _, tag := range tags {
					if s, ok := tag.(string); ok {
						tagStrs = append(tagStrs, s)
					}
				}
				sort.Strings(tagStrs)
				expected := []string{"k3s-master", "k3s-node"}
				sort.Strings(expected)
				assert.Equal(t, expected, tagStrs, "Master Instance: tags 불일치")
			}

			// shielded_instance_config 검증
			if shielded, ok := resource.AttributeValues["shielded_instance_config"].([]interface{}); ok && len(shielded) > 0 {
				if config, ok := shielded[0].(map[string]interface{}); ok {
					assert.Equal(t, true, config["enable_secure_boot"],
						"Master Instance: enable_secure_boot=true 필요")
					assert.Equal(t, true, config["enable_vtpm"],
						"Master Instance: enable_vtpm=true 필요")
					assert.Equal(t, true, config["enable_integrity_monitoring"],
						"Master Instance: enable_integrity_monitoring=true 필요")
				}
			} else {
				t.Error("Master Instance: shielded_instance_config 블록이 없습니다")
			}

			// access_config 존재 확인 (static IP 참조)
			if ni, ok := resource.AttributeValues["network_interface"].([]interface{}); ok && len(ni) > 0 {
				if niMap, ok := ni[0].(map[string]interface{}); ok {
					if ac, ok := niMap["access_config"].([]interface{}); ok {
						assert.Greater(t, len(ac), 0,
							"Master Instance: access_config (static IP)이 설정되어야 합니다")
					}
				}
			}

			t.Log("Master Instance 보안 설정 검증 완료")
		}
	})

	// ========================================================================
	// Subtest 8: WorkerTemplateConfig - Worker Instance Template 설정
	// ========================================================================
	t.Run("WorkerTemplateConfig", func(t *testing.T) {
		for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
			if !strings.HasPrefix(resourceAddr, "google_compute_instance_template.") {
				continue
			}

			// tags 검증
			if tags, ok := resource.AttributeValues["tags"].([]interface{}); ok {
				var tagStrs []string
				for _, tag := range tags {
					if s, ok := tag.(string); ok {
						tagStrs = append(tagStrs, s)
					}
				}
				sort.Strings(tagStrs)
				expected := []string{"k3s-node", "k3s-worker"}
				sort.Strings(expected)
				assert.Equal(t, expected, tagStrs, "Worker Template: tags 불일치")
			}

			// shielded_instance_config 검증
			if shielded, ok := resource.AttributeValues["shielded_instance_config"].([]interface{}); ok && len(shielded) > 0 {
				if config, ok := shielded[0].(map[string]interface{}); ok {
					assert.Equal(t, true, config["enable_secure_boot"],
						"Worker Template: enable_secure_boot=true 필요")
					assert.Equal(t, true, config["enable_vtpm"],
						"Worker Template: enable_vtpm=true 필요")
					assert.Equal(t, true, config["enable_integrity_monitoring"],
						"Worker Template: enable_integrity_monitoring=true 필요")
				}
			} else {
				t.Error("Worker Template: shielded_instance_config 블록이 없습니다")
			}

			// scheduling 검증 (test 환경: use_spot=false -> preemptible=false)
			if scheduling, ok := resource.AttributeValues["scheduling"].([]interface{}); ok && len(scheduling) > 0 {
				if config, ok := scheduling[0].(map[string]interface{}); ok {
					assert.Equal(t, false, config["preemptible"],
						"Worker Template: test 환경에서 preemptible=false 필요")
				}
			}

			t.Log("Worker Template 설정 검증 완료")
		}
	})

	// ========================================================================
	// Subtest 9: MIGConfig - MIG 구성 검증
	// ========================================================================
	t.Run("MIGConfig", func(t *testing.T) {
		for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
			if !strings.HasPrefix(resourceAddr, "google_compute_instance_group_manager.") {
				continue
			}

			// target_size == worker_count
			if targetSize, ok := resource.AttributeValues["target_size"].(float64); ok {
				assert.Equal(t, float64(DefaultWorkerCount), targetSize,
					"MIG target_size는 worker_count(%d)와 동일해야 합니다", DefaultWorkerCount)
			}

			// update_policy 검증
			if updatePolicy, ok := resource.AttributeValues["update_policy"].([]interface{}); ok && len(updatePolicy) > 0 {
				if policy, ok := updatePolicy[0].(map[string]interface{}); ok {
					assert.Equal(t, "PROACTIVE", policy["type"],
						"MIG update_policy type=PROACTIVE 필요")
					if maxSurge, ok := policy["max_surge_fixed"].(float64); ok {
						assert.Equal(t, float64(1), maxSurge,
							"MIG update_policy max_surge_fixed=1 필요")
					}
					if maxUnavail, ok := policy["max_unavailable_fixed"].(float64); ok {
						assert.Equal(t, float64(0), maxUnavail,
							"MIG update_policy max_unavailable_fixed=0 필요")
					}
				}
			}

			t.Log("MIG 구성 검증 완료")
		}
	})

	// ========================================================================
	// Subtest 10: IAMRolesLeastPrivilege - IAM Role 최소 권한 검증
	// ========================================================================
	t.Run("IAMRolesLeastPrivilege", func(t *testing.T) {
		allowedRoles := map[string]bool{
			"roles/logging.logWriter":              false,
			"roles/monitoring.metricWriter":        false,
			"roles/secretmanager.secretAccessor":   false,
		}

		iamCount := 0
		for resourceAddr, resource := range planStruct.ResourcePlannedValuesMap {
			if !strings.HasPrefix(resourceAddr, "google_project_iam_member.") {
				continue
			}
			iamCount++

			if role, ok := resource.AttributeValues["role"].(string); ok {
				if _, expected := allowedRoles[role]; expected {
					allowedRoles[role] = true
				} else {
					t.Errorf("미허용 IAM Role 발견: %s (최소 권한 원칙 위반)", role)
				}
			}
		}

		assert.Equal(t, 3, iamCount, "google_project_iam_member는 정확히 3개여야 합니다")

		for role, found := range allowedRoles {
			assert.True(t, found, "필수 IAM Role '%s'가 누락되었습니다", role)
		}
	})

	// ========================================================================
	// Subtest 11: ServiceAccountConfig - Service Account 생성 검증
	// ========================================================================
	t.Run("ServiceAccountConfig", func(t *testing.T) {
		saFound := false
		for resourceAddr := range planStruct.ResourcePlannedValuesMap {
			if strings.HasPrefix(resourceAddr, "google_service_account.") {
				saFound = true
				break
			}
		}
		assert.True(t, saFound, "google_service_account 리소스가 Plan에 없습니다")
	})

	// ========================================================================
	// Subtest 12: SensitiveVariablesMarked - variables.tf의 sensitive 설정 검증
	// ========================================================================
	t.Run("SensitiveVariablesMarked", func(t *testing.T) {
		variablesPath := filepath.Join(GetTerraformDir(), "variables.tf")
		content, err := os.ReadFile(variablesPath)
		require.NoError(t, err, "variables.tf 읽기 실패")

		hcl := string(content)

		// 민감 변수 목록
		sensitiveVars := []string{"postgres_password", "grafana_admin_password"}

		// 각 변수 블록에서 sensitive = true 설정 확인
		for _, varName := range sensitiveVars {
			// variable "변수명" { ... } 블록을 찾아서 sensitive = true 포함 여부 확인
			pattern := fmt.Sprintf(`variable\s+"%s"\s*\{[^}]*sensitive\s*=\s*true`, varName)
			matched, err := regexp.MatchString(pattern, hcl)
			require.NoError(t, err, "정규식 매칭 오류")
			assert.True(t, matched,
				"변수 '%s'에 sensitive = true가 설정되어야 합니다", varName)
		}

		t.Logf("민감 변수 sensitive 마킹 검증 완료: %v", sensitiveVars)
	})
}
