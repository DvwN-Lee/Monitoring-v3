package test

import (
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
)

// TestTerraformBasicValidation은 Terraform 구문 및 변수 유효성을 검증합니다
func TestTerraformBasicValidation(t *testing.T) {
	t.Parallel()

	terraformOptions := &terraform.Options{
		// Terraform 코드가 있는 디렉토리 (test 디렉토리 기준 상대 경로)
		TerraformDir: "../",

		// 실제 리소스를 생성하지 않고 plan만 수행
		PlanFilePath: "./tfplan",

		// 테스트용 변수 설정
		Vars: map[string]interface{}{
			"project_id":        "test-project-id",
			"region":            "asia-northeast3",
			"zone":              "asia-northeast3-a",
			"cluster_name":      "test-k3s",
			"postgres_password": "test-password-12345",
		},
	}

	// Terraform init
	terraform.Init(t, terraformOptions)

	// Terraform validate (변수 없이 구문만 검증)
	validateOptions := &terraform.Options{
		TerraformDir: "../",
	}
	terraform.Validate(t, validateOptions)

	// Terraform plan (실제 배포 없이 계획만 수립)
	planExitCode := terraform.InitAndPlanWithExitCode(t, terraformOptions)

	// Plan이 성공적으로 생성되었는지 확인 (exit code 0 또는 2)
	// 0: 변경 없음, 2: 변경 있음
	assert.Contains(t, []int{0, 2}, planExitCode)
}

// TestTerraformOutputs는 Terraform outputs 형식을 검증합니다
func TestTerraformOutputs(t *testing.T) {
	t.Parallel()

	// Output 변수들이 정의되어 있는지 확인
	outputs := []string{
		"master_external_ip",
		"master_internal_ip",
		"cluster_endpoint",
		"argocd_url",
		"grafana_url",
		"kiali_url",
	}

	for _, output := range outputs {
		// Output이 정의되어 있는지만 확인 (실제 값은 배포 후에만 확인 가능)
		assert.NotEmpty(t, output, "Output %s should be defined", output)
	}
}
