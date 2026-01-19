import { test, expect } from '@playwright/test';

// Environment variables with defaults
const CLUSTER_IP = process.env.CLUSTER_IP || '34.50.8.19';
const GRAFANA_PORT = process.env.GRAFANA_PORT || '31300';
const PROMETHEUS_PORT = process.env.PROMETHEUS_PORT || '31090';
const KIALI_PORT = process.env.KIALI_PORT || '31200';
const GRAFANA_ADMIN_PASSWORD = process.env.GRAFANA_ADMIN_PASSWORD || 'admin';

const GRAFANA_URL = `http://${CLUSTER_IP}:${GRAFANA_PORT}`;
const PROMETHEUS_URL = `http://${CLUSTER_IP}:${PROMETHEUS_PORT}`;
const KIALI_URL = `http://${CLUSTER_IP}:${KIALI_PORT}`;

const SCREENSHOTS_DIR = 'tests/e2e/screenshots';

test.describe('E2E Dashboard Tests', () => {

  test.describe('Grafana Tests', () => {

    test('Grafana 로그인 페이지 접근', async ({ page }) => {
      await page.goto(`${GRAFANA_URL}/login`);
      await page.waitForLoadState('load');

      // Grafana 로그인 페이지 확인
      const title = await page.title();
      expect(title).toContain('Grafana');

      // 로그인 폼 요소 확인
      const usernameInput = page.locator('input[name="user"]');
      const passwordInput = page.locator('input[name="password"]');

      await expect(usernameInput).toBeVisible();
      await expect(passwordInput).toBeVisible();

      await page.screenshot({
        path: `${SCREENSHOTS_DIR}/grafana-login-page.png`,
        fullPage: true
      });

      console.log('Grafana 로그인 페이지 스크린샷 저장 완료');
    });

    test('Grafana 로그인 및 대시보드 접근', async ({ page }) => {
      await page.goto(`${GRAFANA_URL}/login`);
      await page.waitForLoadState('load');

      // 로그인 수행
      await page.fill('input[name="user"]', 'admin');
      await page.fill('input[name="password"]', GRAFANA_ADMIN_PASSWORD);
      await page.click('button[type="submit"]');

      // 로그인 성공 후 대시보드 페이지 대기
      await page.waitForURL('**/d/**', { timeout: 15000 }).catch(() => {
        // 홈 페이지로 리다이렉트되는 경우
        return page.waitForURL('**/', { timeout: 5000 });
      });

      await page.waitForLoadState('load');

      // 로그인 성공 확인 (로그아웃 버튼 또는 사용자 메뉴 존재)
      const userMenu = page.locator('[aria-label="User menu"]').or(page.locator('[data-testid="sidemenu"]'));
      await expect(userMenu.first()).toBeVisible({ timeout: 10000 });

      await page.screenshot({
        path: `${SCREENSHOTS_DIR}/grafana-dashboard.png`,
        fullPage: true
      });

      console.log('Grafana 대시보드 스크린샷 저장 완료');
    });

    test('Grafana Health API 검증', async ({ request }) => {
      const response = await request.get(`${GRAFANA_URL}/api/health`);
      expect(response.ok()).toBeTruthy();

      const body = await response.json();
      expect(body.database).toBe('ok');

      console.log('Grafana Health:', JSON.stringify(body));
    });

    test('Grafana Datasources 확인 (인증 필요)', async ({ request }) => {
      // 인증 없이 접근 시 401 응답 확인
      const response = await request.get(`${GRAFANA_URL}/api/datasources`);
      expect(response.status()).toBe(401);

      console.log('Grafana Datasources API: 인증 필요 (401) 확인');
    });

  });

  test.describe('Prometheus Tests', () => {

    test('Prometheus Targets 페이지 접근', async ({ page }) => {
      await page.goto(`${PROMETHEUS_URL}/targets`);
      // Prometheus는 지속적 polling으로 networkidle 대신 domcontentloaded 사용
      await page.waitForLoadState('domcontentloaded');
      await page.waitForTimeout(2000);

      // Prometheus 페이지 확인
      const content = await page.content();
      expect(content).toContain('Prometheus');

      await page.screenshot({
        path: `${SCREENSHOTS_DIR}/prometheus-targets.png`,
        fullPage: true
      });

      console.log('Prometheus Targets 스크린샷 저장 완료');
    });

    test('Prometheus Health API 검증', async ({ request }) => {
      const response = await request.get(`${PROMETHEUS_URL}/-/healthy`);
      expect(response.ok()).toBeTruthy();

      const text = await response.text();
      expect(text).toContain('Healthy');

      console.log('Prometheus Health: OK');
    });

    test('Prometheus Targets API 검증', async ({ request }) => {
      const response = await request.get(`${PROMETHEUS_URL}/api/v1/targets`);
      expect(response.ok()).toBeTruthy();

      const body = await response.json();
      expect(body.status).toBe('success');
      expect(body.data).toBeDefined();
      expect(body.data.activeTargets).toBeDefined();

      const activeTargets = body.data.activeTargets;
      console.log(`Prometheus Active Targets: ${activeTargets.length}`);

      // 활성 타겟이 존재하는지 확인
      expect(activeTargets.length).toBeGreaterThan(0);
    });

    test('Prometheus Query API 검증', async ({ request }) => {
      const response = await request.get(`${PROMETHEUS_URL}/api/v1/query?query=up`);
      expect(response.ok()).toBeTruthy();

      const body = await response.json();
      expect(body.status).toBe('success');
      expect(body.data).toBeDefined();
      expect(body.data.resultType).toBe('vector');

      console.log('Prometheus Query API: OK');
    });

  });

  test.describe('Kiali Tests', () => {

    test('Kiali 메인 페이지 접근', async ({ page }) => {
      await page.goto(KIALI_URL);
      await page.waitForLoadState('load');

      // Kiali 페이지 확인
      const title = await page.title();
      expect(title.toLowerCase()).toContain('kiali');

      await page.screenshot({
        path: `${SCREENSHOTS_DIR}/kiali-main.png`,
        fullPage: true
      });

      console.log('Kiali 메인 페이지 스크린샷 저장 완료');
    });

    test('Kiali Service Graph 페이지 접근', async ({ page }) => {
      // Kiali Graph 페이지로 직접 이동
      await page.goto(`${KIALI_URL}/console/graph/namespaces/?namespaces=titanium-prod`);
      await page.waitForLoadState('load');
      await page.waitForTimeout(2000); // Graph 렌더링 대기

      await page.screenshot({
        path: `${SCREENSHOTS_DIR}/kiali-service-graph.png`,
        fullPage: true
      });

      console.log('Kiali Service Graph 스크린샷 저장 완료');
    });

    test('Kiali Status API 검증', async ({ request }) => {
      const response = await request.get(`${KIALI_URL}/api/status`);
      expect(response.ok()).toBeTruthy();

      const body = await response.json();
      expect(body.status).toBeDefined();

      console.log('Kiali Status:', JSON.stringify(body.status || body));
    });

    test('Kiali Namespaces API 검증', async ({ request }) => {
      const response = await request.get(`${KIALI_URL}/api/namespaces`);
      expect(response.ok()).toBeTruthy();

      const body = await response.json();
      expect(Array.isArray(body)).toBeTruthy();

      // titanium-prod namespace 존재 확인
      const hasTargetNamespace = body.some((ns: { name: string }) => ns.name === 'titanium-prod');
      expect(hasTargetNamespace).toBeTruthy();

      console.log(`Kiali Namespaces: ${body.map((ns: { name: string }) => ns.name).join(', ')}`);
    });

    test('Kiali Istio Config API 검증', async ({ request }) => {
      const response = await request.get(`${KIALI_URL}/api/istio/config`);
      expect(response.ok()).toBeTruthy();

      console.log('Kiali Istio Config API: OK');
    });

  });

  test.describe('Integration Tests', () => {

    test('모든 서비스 Health Check 통합 테스트', async ({ request }) => {
      const services = [
        { name: 'Grafana', url: `${GRAFANA_URL}/api/health` },
        { name: 'Prometheus', url: `${PROMETHEUS_URL}/-/healthy` },
        { name: 'Kiali', url: `${KIALI_URL}/api/status` },
      ];

      const results: { name: string; status: number; ok: boolean }[] = [];

      for (const service of services) {
        const response = await request.get(service.url, { timeout: 10000 });
        results.push({
          name: service.name,
          status: response.status(),
          ok: response.ok()
        });
      }

      console.log('Service Health Summary:');
      results.forEach(r => {
        console.log(`  ${r.name}: ${r.ok ? 'OK' : 'FAIL'} (HTTP ${r.status})`);
      });

      // 모든 서비스가 정상이어야 함
      const allHealthy = results.every(r => r.ok);
      expect(allHealthy).toBeTruthy();
    });

    test('Monitoring Stack 연동 확인', async ({ request }) => {
      // Prometheus에서 Grafana 관련 메트릭 수집 확인
      const prometheusResponse = await request.get(
        `${PROMETHEUS_URL}/api/v1/query?query=up{job=~".*grafana.*"}`
      );
      expect(prometheusResponse.ok()).toBeTruthy();

      const prometheusBody = await prometheusResponse.json();
      console.log('Prometheus Grafana Metrics:', JSON.stringify(prometheusBody.data));

      // Kiali에서 Istio 설정 확인
      const kialiResponse = await request.get(`${KIALI_URL}/api/istio/config`);
      expect(kialiResponse.ok()).toBeTruthy();

      console.log('Monitoring Stack 연동 확인 완료');
    });

  });

});
