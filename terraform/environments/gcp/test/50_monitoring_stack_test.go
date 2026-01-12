package test

import (
	"fmt"
	"testing"

	"github.com/gruntwork-io/terratest/modules/ssh"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMonitoringStackValidation Layer 5: Monitoring Stack Deep Validation
// 비용: 높음 (기존 인프라 활용 시 낮음)
// 실행 시간: 15-20분
// 목적: Prometheus, Grafana, Loki, Kiali의 상세 검증
func TestMonitoringStackValidation(t *testing.T) {
	t.Parallel()

	// GetApplyTerraformOptions: 고유 클러스터 이름 사용 (병렬 테스트 충돌 방지)
	terraformOptions := GetApplyTerraformOptions(t)
	defer terraform.Destroy(t, terraformOptions)
	terraform.InitAndApply(t, terraformOptions)

	// 동적으로 생성된 cluster_name 사용
	clusterName := terraformOptions.Vars["cluster_name"].(string)

	// Issue #37: wait_for_instances=false로 변경됨에 따라
	// Worker 인스턴스 RUNNING 상태 대기 (MIG 15분 타임아웃 방지)
	t.Log("Worker 인스턴스 RUNNING 상태 대기 중...")
	workerNames, err := GetWorkerInstanceNamesWithRetry(t, clusterName, DefaultProjectID, DefaultZone, DefaultWorkerCount)
	require.NoError(t, err, "Worker 인스턴스 RUNNING 대기 실패")
	t.Logf("Worker 인스턴스 RUNNING 확인: %v", workerNames)

	masterPublicIP := terraform.Output(t, terraformOptions, "master_external_ip")
	waitForK3sCluster(t, masterPublicIP)

	privateKeyPath, _ := GetSSHKeyPairPath()
	host := CreateSSHHost(t, masterPublicIP, privateKeyPath)

	// Monitoring Stack이 완전히 준비될 때까지 단계별 대기 (Issue #27)
	// 1단계: ArgoCD Application Healthy 대기 (최대 10분)
	// 2단계: Monitoring Pod Ready 확인 (최대 3분)
	err = WaitForMonitoringStackReady(t, host)
	require.NoError(t, err, "Monitoring Stack 준비 실패")

	// Monitoring Stack Subtests
	t.Run("PrometheusHealth", func(t *testing.T) { testPrometheusHealth(t, host) })
	t.Run("PrometheusTargets", func(t *testing.T) { testPrometheusTargets(t, host) })
	t.Run("PrometheusMetrics", func(t *testing.T) { testPrometheusMetrics(t, host) })
	t.Run("GrafanaHealth", func(t *testing.T) { testGrafanaHealth(t, host) })
	t.Run("GrafanaDataSources", func(t *testing.T) { testGrafanaDataSources(t, host) })
	t.Run("LokiHealth", func(t *testing.T) { testLokiHealth(t, host) })
	t.Run("KialiHealth", func(t *testing.T) { testKialiHealth(t, host) })
	t.Run("KialiNamespaces", func(t *testing.T) { testKialiNamespaces(t, host) })

	// Application Subtests (Issue #27)
	t.Run("ApplicationPodsReady", func(t *testing.T) { testApplicationPodsReady(t, host) })
	t.Run("ApplicationHealth", func(t *testing.T) { testApplicationHealth(t, host) })
}

// testPrometheusHealth Prometheus 서버 health 상태 확인
func testPrometheusHealth(t *testing.T, host ssh.Host) {
	t.Log("Prometheus health 검증 시작")

	err := VerifyPrometheusHealthyWithRetry(t, host)
	require.NoError(t, err, "Prometheus health check 실패 (재시도 후)")

	t.Log("Prometheus가 healthy 상태입니다")
}

// testPrometheusTargets Prometheus scrape target UP 상태 확인
func testPrometheusTargets(t *testing.T, host ssh.Host) {
	t.Log("Prometheus targets 검증 시작")

	// 최소 target 개수만 확인 (job 이름은 Helm release에 따라 다를 수 있음)
	err := VerifyPrometheusMinTargetsUpWithRetry(t, host, "31090", 3)
	require.NoError(t, err, "Prometheus targets 검증 실패 (재시도 후)")

	t.Log("Prometheus targets가 정상적으로 UP 상태입니다")
}

// testPrometheusMetrics 실제 metric 수집 확인
func testPrometheusMetrics(t *testing.T, host ssh.Host) {
	t.Log("Prometheus metrics 수집 검증 시작")

	// 필수 Metric 쿼리
	testQueries := map[string]string{
		"up":                          "up",
		"node_cpu":                    "node_cpu_seconds_total",
		"container_memory":            "container_memory_usage_bytes",
		"kube_pod_status":             "kube_pod_status_phase",
	}

	for name, query := range testQueries {
		t.Logf("Metric 쿼리 실행: %s", name)

		resultCount, err := QueryPrometheusMetricWithRetry(t, host, query)
		require.NoError(t, err, fmt.Sprintf("Metric '%s' 쿼리 실패 (재시도 후)", name))
		assert.Greater(t, resultCount, 0, fmt.Sprintf("Metric '%s'의 결과가 0개입니다", name))

		t.Logf("Metric '%s': %d개 결과 확인", name, resultCount)
	}

	t.Log("모든 필수 metrics가 정상적으로 수집되고 있습니다")
}

// testGrafanaHealth Grafana 서버 health 상태 확인
func testGrafanaHealth(t *testing.T, host ssh.Host) {
	t.Log("Grafana health 검증 시작")

	err := VerifyGrafanaHealthyWithRetry(t, host)
	require.NoError(t, err, "Grafana health check 실패 (재시도 후)")

	t.Log("Grafana가 healthy 상태입니다")
}

// testGrafanaDataSources Grafana DataSource 연결 상태 확인
func testGrafanaDataSources(t *testing.T, host ssh.Host) {
	t.Log("Grafana DataSources 검증 시작")

	requiredSources := []string{"Prometheus", "Loki"}

	err := VerifyGrafanaDataSourcesWithRetry(t, host, requiredSources)
	require.NoError(t, err, "Grafana DataSource 검증 실패 (재시도 후)")

	t.Logf("모든 필수 DataSource가 연결되어 있습니다: %v", requiredSources)
}

// testLokiHealth Loki 서버 ready 상태 확인
func testLokiHealth(t *testing.T, host ssh.Host) {
	t.Log("Loki health 검증 시작")

	err := VerifyLokiReadyWithRetry(t, host)
	require.NoError(t, err, "Loki ready check 실패 (재시도 후)")

	t.Log("Loki가 ready 상태입니다")
}

// testKialiHealth Kiali 서버 health 상태 확인
func testKialiHealth(t *testing.T, host ssh.Host) {
	t.Log("Kiali health 검증 시작")

	err := VerifyKialiHealthyWithRetry(t, host)
	require.NoError(t, err, "Kiali health check 실패 (재시도 후)")

	t.Log("Kiali가 healthy 상태입니다")
}

// testKialiNamespaces Kiali namespace 조회 확인
func testKialiNamespaces(t *testing.T, host ssh.Host) {
	t.Log("Kiali namespaces 검증 시작")

	namespaces, err := GetKialiNamespacesWithRetry(t, host)
	require.NoError(t, err, "Kiali namespace 조회 실패 (재시도 후)")

	// 필수 namespace 확인
	requiredNamespaces := []string{"istio-system", "monitoring"}
	foundMap := make(map[string]bool)
	for _, ns := range namespaces {
		foundMap[ns] = true
	}

	for _, required := range requiredNamespaces {
		assert.True(t, foundMap[required], fmt.Sprintf("필수 namespace '%s'가 Kiali에 없습니다", required))
	}

	t.Logf("Kiali에서 %d개 namespace를 관리하고 있습니다", len(namespaces))
}

// testApplicationPodsReady Application Pod Ready 상태 확인
func testApplicationPodsReady(t *testing.T, host ssh.Host) {
	t.Log("Application Pods Ready 검증 시작")

	err := VerifyApplicationPodsReadyWithRetry(t, host)
	require.NoError(t, err, "Application Pods Ready 검증 실패 (재시도 후)")

	t.Log("모든 Application Pod가 Ready 상태입니다")
}

// testApplicationHealth Application Health endpoint 확인
func testApplicationHealth(t *testing.T, host ssh.Host) {
	t.Log("Application Health 검증 시작")

	err := VerifyApplicationHealthWithRetry(t, host)
	require.NoError(t, err, "Application Health 검증 실패 (재시도 후)")

	t.Log("모든 Application이 healthy 상태입니다")
}
