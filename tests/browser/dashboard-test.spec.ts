import { test, expect } from '@playwright/test';

const BASE_IP = '34.47.68.205';
const GRAFANA_URL = `http://${BASE_IP}:31300`;
const PROMETHEUS_URL = `http://${BASE_IP}:31090`;
const ARGOCD_URL = `http://${BASE_IP}:30080`;

test.describe('Dashboard Browser Tests', () => {

  test('Grafana Dashboard 접근 및 스크린샷', async ({ page }) => {
    await page.goto(GRAFANA_URL);
    await page.waitForLoadState('networkidle');

    // Grafana 로그인 페이지 또는 대시보드 확인
    const title = await page.title();
    expect(title).toContain('Grafana');

    await page.screenshot({
      path: 'tests/browser/screenshots/grafana-login.png',
      fullPage: true
    });

    console.log('Grafana 스크린샷 저장 완료');
  });

  test('Prometheus Targets 확인', async ({ page }) => {
    await page.goto(`${PROMETHEUS_URL}/targets`);
    // Prometheus Targets 페이지는 지속적 polling으로 networkidle 불가
    await page.waitForLoadState('domcontentloaded');
    await page.waitForTimeout(3000); // Target 목록 렌더링 대기

    // Prometheus 페이지 확인
    const content = await page.content();
    expect(content).toContain('Prometheus');

    await page.screenshot({
      path: 'tests/browser/screenshots/prometheus-targets.png',
      fullPage: true
    });

    console.log('Prometheus Targets 스크린샷 저장 완료');
  });

  test('ArgoCD Applications 확인', async ({ page }) => {
    await page.goto(ARGOCD_URL);
    await page.waitForLoadState('networkidle');

    // ArgoCD 페이지 확인
    const title = await page.title();
    expect(title).toContain('Argo');

    await page.screenshot({
      path: 'tests/browser/screenshots/argocd-apps.png',
      fullPage: true
    });

    console.log('ArgoCD Applications 스크린샷 저장 완료');
  });

  test('Grafana Health API 확인', async ({ request }) => {
    const response = await request.get(`${GRAFANA_URL}/api/health`);
    expect(response.ok()).toBeTruthy();

    const body = await response.json();
    expect(body.database).toBe('ok');

    console.log('Grafana Health:', body);
  });

  test('Prometheus Health API 확인', async ({ request }) => {
    const response = await request.get(`${PROMETHEUS_URL}/-/healthy`);
    expect(response.ok()).toBeTruthy();

    const text = await response.text();
    expect(text).toContain('Healthy');

    console.log('Prometheus Health: OK');
  });

});
