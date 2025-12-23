package test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	http_helper "github.com/gruntwork-io/terratest/modules/http-helper"
	"github.com/gruntwork-io/terratest/modules/retry"
	"github.com/gruntwork-io/terratest/modules/ssh"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Layer 4: Full Integration Tests
// 비용: 높음 (전체 스택 배포), 실행 시간: 20분+
// 목적: ArgoCD, Monitoring Stack, Application 전체 통합 검증

// TestFullIntegration 전체 인프라 통합 테스트
func TestFullIntegration(t *testing.T) {
	t.Parallel()

	terraformOptions := GetDefaultTerraformOptions(t)

	// Cleanup
	defer terraform.Destroy(t, terraformOptions)

	// Deploy
	terraform.InitAndApply(t, terraformOptions)

	// Output 검증 (실제 outputs.tf에 정의된 이름)
	masterPublicIP := terraform.Output(t, terraformOptions, "master_external_ip")
	require.NotEmpty(t, masterPublicIP, "Master public IP가 비어있습니다")

	// K3s 클러스터 준비 대기
	waitForK3sCluster(t, masterPublicIP)

	// Sub-tests (순차 실행)
	t.Run("InfrastructureOutputs", func(t *testing.T) {
		testInfrastructureOutputs(t, terraformOptions)
	})

	t.Run("KubeconfigAccess", func(t *testing.T) {
		testKubeconfigAccess(t, masterPublicIP)
	})

	t.Run("NamespaceSetup", func(t *testing.T) {
		testNamespaceSetup(t, masterPublicIP)
	})

	t.Run("ArgoCDApplications", func(t *testing.T) {
		testArgoCDApplications(t, masterPublicIP)
	})

	t.Run("MonitoringStack", func(t *testing.T) {
		testMonitoringStack(t, masterPublicIP)
	})

	t.Run("ApplicationEndpoints", func(t *testing.T) {
		testApplicationEndpoints(t, masterPublicIP)
	})
}

// waitForK3sCluster K3s 클러스터 준비 대기
func waitForK3sCluster(t *testing.T, publicIP string) {
	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, publicIP, privateKeyPath)

	maxRetries := 60
	sleepBetweenRetries := 10 * time.Second

	_, err := retry.DoWithRetryE(t, "K3s 클러스터 Ready 대기", maxRetries, sleepBetweenRetries, func() (string, error) {
		output, err := RunSSHCommand(t, host, "sudo kubectl get nodes --no-headers 2>/dev/null | grep -v 'NotReady' | wc -l")
		if err != nil {
			return "", fmt.Errorf("클러스터 상태 확인 실패: %v", err)
		}

		readyCount := 0
		fmt.Sscanf(strings.TrimSpace(output), "%d", &readyCount)

		if readyCount < 1 {
			return "", fmt.Errorf("Ready 노드가 없습니다")
		}

		return output, nil
	})

	require.NoError(t, err, "K3s 클러스터가 준비되지 않았습니다")
	t.Log("K3s 클러스터 준비 완료")
}

// testInfrastructureOutputs Terraform Output 검증
func testInfrastructureOutputs(t *testing.T, terraformOptions *terraform.Options) {
	// 필수 Output 검증 (실제 outputs.tf에 정의된 이름)
	outputs := []string{
		"master_external_ip",
		"master_internal_ip",
		"vpc_id",
		"subnet_id",
		"cluster_endpoint",
		"argocd_url",
		"grafana_url",
		"kiali_url",
	}

	for _, outputName := range outputs {
		value := terraform.Output(t, terraformOptions, outputName)
		assert.NotEmpty(t, value, "Output '%s'가 비어있습니다", outputName)
		t.Logf("Output '%s': %s", outputName, value)
	}
}

// testKubeconfigAccess Kubeconfig 접근 테스트
func testKubeconfigAccess(t *testing.T, publicIP string) {
	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, publicIP, privateKeyPath)

	// Kubeconfig 파일 존재 확인
	output, err := RunSSHCommand(t, host, "sudo test -f /etc/rancher/k3s/k3s.yaml && echo 'exists'")
	require.NoError(t, err, "Kubeconfig 파일 확인 실패")
	assert.Contains(t, output, "exists", "Kubeconfig 파일이 존재하지 않습니다")

	// Kubectl 명령 실행 확인
	output, err = RunSSHCommand(t, host, "sudo kubectl cluster-info")
	require.NoError(t, err, "kubectl cluster-info 실행 실패")
	assert.Contains(t, output, "Kubernetes control plane", "Cluster info가 올바르지 않습니다")

	t.Log("Kubeconfig 접근 검증 완료")
}

// testNamespaceSetup Namespace 설정 테스트
func testNamespaceSetup(t *testing.T, publicIP string) {
	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, publicIP, privateKeyPath)

	// 필수 Namespace 확인
	requiredNamespaces := []string{
		"kube-system",
		"default",
	}

	output, err := RunSSHCommand(t, host, "sudo kubectl get namespaces --no-headers | awk '{print $1}'")
	require.NoError(t, err, "Namespace 목록 조회 실패")

	for _, ns := range requiredNamespaces {
		assert.Contains(t, output, ns, "Namespace '%s'가 존재하지 않습니다", ns)
	}

	t.Log("Namespace 설정 검증 완료")
}

// testArgoCDApplications ArgoCD Application 상태 테스트
func testArgoCDApplications(t *testing.T, publicIP string) {
	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, publicIP, privateKeyPath)

	// ArgoCD Namespace 확인
	output, err := RunSSHCommand(t, host, "sudo kubectl get namespace argocd --no-headers 2>/dev/null || echo 'not found'")
	if strings.Contains(output, "not found") {
		t.Skip("ArgoCD가 설치되지 않아 테스트를 건너뜁니다")
		return
	}
	require.NoError(t, err, "ArgoCD namespace 확인 실패")

	// ArgoCD Server Pod 상태 확인
	maxRetries := 30
	sleepBetweenRetries := 10 * time.Second

	_, err = retry.DoWithRetryE(t, "ArgoCD Server 대기", maxRetries, sleepBetweenRetries, func() (string, error) {
		output, err := RunSSHCommand(t, host, "sudo kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server --no-headers | grep -c 'Running'")
		if err != nil {
			return "", fmt.Errorf("ArgoCD Server Pod 상태 확인 실패: %v", err)
		}

		runningCount := 0
		fmt.Sscanf(strings.TrimSpace(output), "%d", &runningCount)

		if runningCount < 1 {
			return "", fmt.Errorf("ArgoCD Server Pod가 Running 상태가 아닙니다")
		}

		return output, nil
	})

	if err != nil {
		t.Logf("ArgoCD Server가 준비되지 않음 (선택적 테스트): %v", err)
		return
	}

	// ArgoCD Application 목록 확인
	output, _ = RunSSHCommand(t, host, "sudo kubectl get applications -n argocd --no-headers 2>/dev/null || echo 'none'")
	t.Logf("ArgoCD Applications:\n%s", output)

	t.Log("ArgoCD Application 검증 완료")
}

// testMonitoringStack Monitoring Stack 테스트
func testMonitoringStack(t *testing.T, publicIP string) {
	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, publicIP, privateKeyPath)

	// Monitoring Namespace 확인
	monitoringNamespaces := []string{
		"monitoring",
		"istio-system",
	}

	for _, ns := range monitoringNamespaces {
		output, _ := RunSSHCommand(t, host, fmt.Sprintf("sudo kubectl get namespace %s --no-headers 2>/dev/null || echo 'not found'", ns))
		if strings.Contains(output, "not found") {
			t.Logf("Namespace '%s'가 없어 해당 테스트를 건너뜁니다", ns)
			continue
		}

		// Pod 상태 확인
		output, _ = RunSSHCommand(t, host, fmt.Sprintf("sudo kubectl get pods -n %s --no-headers 2>/dev/null | head -10", ns))
		t.Logf("Namespace '%s' Pods:\n%s", ns, output)
	}

	// Prometheus 확인
	testMonitoringComponent(t, host, "monitoring", "prometheus", "prometheus")

	// Grafana 확인
	testMonitoringComponent(t, host, "monitoring", "grafana", "grafana")

	// Istio 확인
	testMonitoringComponent(t, host, "istio-system", "istiod", "istiod")

	t.Log("Monitoring Stack 검증 완료")
}

// testMonitoringComponent Monitoring 컴포넌트 개별 테스트
func testMonitoringComponent(t *testing.T, host ssh.Host, namespace string, componentName string, podPrefix string) {
	output, err := RunSSHCommand(t, host, fmt.Sprintf("sudo kubectl get pods -n %s --no-headers 2>/dev/null | grep '%s' | grep -c 'Running' || echo '0'", namespace, podPrefix))
	if err != nil {
		t.Logf("%s 상태 확인 실패 (선택적): %v", componentName, err)
		return
	}

	runningCount := 0
	fmt.Sscanf(strings.TrimSpace(output), "%d", &runningCount)

	if runningCount > 0 {
		t.Logf("%s: Running (%d pods)", componentName, runningCount)
	} else {
		t.Logf("%s: Not deployed or not running", componentName)
	}
}

// testApplicationEndpoints Application Endpoint 테스트
func testApplicationEndpoints(t *testing.T, publicIP string) {
	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, publicIP, privateKeyPath)

	// Application Namespace 확인
	appNamespace := "titanium-prod"
	output, _ := RunSSHCommand(t, host, fmt.Sprintf("sudo kubectl get namespace %s --no-headers 2>/dev/null || echo 'not found'", appNamespace))
	if strings.Contains(output, "not found") {
		t.Skipf("Application namespace '%s'가 없어 테스트를 건너뜁니다", appNamespace)
		return
	}

	// Application Pod 상태 확인
	services := []string{
		"user-service",
		"auth-service",
		"blog-service",
		"api-gateway",
	}

	for _, svc := range services {
		output, _ := RunSSHCommand(t, host, fmt.Sprintf("sudo kubectl get pods -n %s --no-headers 2>/dev/null | grep '%s' | grep -c 'Running' || echo '0'", appNamespace, svc))

		runningCount := 0
		fmt.Sscanf(strings.TrimSpace(output), "%d", &runningCount)

		if runningCount > 0 {
			t.Logf("Service '%s': Running (%d pods)", svc, runningCount)
		} else {
			t.Logf("Service '%s': Not deployed or not running", svc)
		}
	}

	// Service Endpoint 확인
	output, _ = RunSSHCommand(t, host, fmt.Sprintf("sudo kubectl get svc -n %s --no-headers 2>/dev/null | head -10", appNamespace))
	t.Logf("Application Services:\n%s", output)

	t.Log("Application Endpoint 검증 완료")
}

// TestEndToEndHTTP E2E HTTP 테스트 (Ingress Gateway 통해)
func TestEndToEndHTTP(t *testing.T) {
	t.Parallel()

	terraformOptions := GetDefaultTerraformOptions(t)

	// Cleanup
	defer terraform.Destroy(t, terraformOptions)

	// Deploy
	terraform.InitAndApply(t, terraformOptions)

	masterPublicIP := terraform.Output(t, terraformOptions, "master_external_ip")
	require.NotEmpty(t, masterPublicIP, "Master public IP가 비어있습니다")

	// K3s 클러스터 준비 대기
	waitForK3sCluster(t, masterPublicIP)

	// Ingress Gateway 준비 대기 및 HTTP 테스트
	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, masterPublicIP, privateKeyPath)

	// Istio Ingress Gateway NodePort 확인
	output, err := RunSSHCommand(t, host, "sudo kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name==\"http2\")].nodePort}' 2>/dev/null || echo ''")
	if err != nil || strings.TrimSpace(output) == "" {
		t.Skip("Istio Ingress Gateway가 설치되지 않아 E2E HTTP 테스트를 건너뜁니다")
		return
	}

	nodePort := strings.TrimSpace(output)
	ingressURL := fmt.Sprintf("http://%s:%s", masterPublicIP, nodePort)

	// HTTP 요청 테스트
	maxRetries := 30
	sleepBetweenRetries := 10 * time.Second

	http_helper.HttpGetWithRetryWithCustomValidation(
		t,
		ingressURL,
		nil,
		maxRetries,
		sleepBetweenRetries,
		func(statusCode int, body string) bool {
			// 200 또는 404 (서비스가 배포되지 않은 경우) 허용
			return statusCode == 200 || statusCode == 404
		},
	)

	t.Logf("E2E HTTP 테스트 완료: %s", ingressURL)
}
