package test

import (
	"testing"
)

// Layer 0: Static Validation Tests
// 비용: $0, 실행 시간: <1분
// 목적: 코드 품질 및 구문 검증

// TestTerraformFormat terraform fmt -check 실행
func TestTerraformFormat(t *testing.T) {
	t.Parallel()

	terraformDir := GetTerraformDir()

	err := TerraformFormatCheck(t, terraformDir)
	if err != nil {
		t.Fatalf("Terraform 포맷 검사 실패. 'terraform fmt -recursive' 실행 필요: %v", err)
	}

	t.Log("Terraform 포맷 검사 통과")
}

// TestTerraformValidate terraform validate 실행
func TestTerraformValidate(t *testing.T) {
	t.Parallel()

	terraformDir := GetTerraformDir()

	err := TerraformValidate(t, terraformDir)
	if err != nil {
		t.Fatalf("Terraform 구문 검증 실패: %v", err)
	}

	t.Log("Terraform 구문 검증 통과")
}
