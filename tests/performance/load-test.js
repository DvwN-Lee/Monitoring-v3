import http from 'k6/http';
import { check, sleep } from 'k6';

// Test configuration
export const options = {
  stages: [
    { duration: '1m', target: 10 },   // Ramp up to 10 users
    { duration: '2m', target: 10 },   // Stay at 10 users
    { duration: '1m', target: 50 },   // Ramp up to 50 users
    { duration: '2m', target: 50 },   // Stay at 50 users
    { duration: '1m', target: 100 },  // Ramp up to 100 users
    { duration: '2m', target: 100 },  // Stay at 100 users
    { duration: '1m', target: 0 },    // Ramp down to 0 users
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'], // 95% of requests should be below 500ms
    http_req_failed: ['rate<0.01'],   // Error rate should be less than 1%
    checks: ['rate>0.99'],            // 99% of checks should pass
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://10.0.11.168:31304';

export default function () {
  // Test 1: Dashboard
  let dashboardRes = http.get(`${BASE_URL}/`);
  check(dashboardRes, {
    'dashboard status 200': (r) => r.status === 200,
    'dashboard response time < 1s': (r) => r.timings.duration < 1000,
  });

  sleep(1);

  // Test 2: Blog
  let blogRes = http.get(`${BASE_URL}/blog/`);
  check(blogRes, {
    'blog status 200': (r) => r.status === 200,
    'blog response time < 1s': (r) => r.timings.duration < 1000,
  });

  sleep(1);

  // Test 3: Blog API
  let blogApiRes = http.get(`${BASE_URL}/blog/api/posts`);
  check(blogApiRes, {
    'blog api status 200': (r) => r.status === 200,
    'blog api response time < 500ms': (r) => r.timings.duration < 500,
  });

  sleep(1);

  // Test 4: Health Check
  let healthRes = http.get(`${BASE_URL}/health`);
  check(healthRes, {
    'health status 200': (r) => r.status === 200,
    'health response time < 200ms': (r) => r.timings.duration < 200,
  });

  sleep(1);
}

export function handleSummary(data) {
  return {
    'stdout': textSummary(data, { indent: ' ', enableColors: true }),
    'tests/performance/results.json': JSON.stringify(data),
  };
}

function textSummary(data, options) {
  const indent = options.indent || '';
  const enableColors = options.enableColors || false;

  let output = '\n' + indent + '=== Performance Test Summary ===\n\n';

  // Metrics
  for (const [name, metric] of Object.entries(data.metrics)) {
    if (metric.values) {
      output += indent + `${name}:\n`;
      if (metric.values.min !== undefined && metric.values.min !== null) {
        output += indent + `  min: ${metric.values.min.toFixed(2)}\n`;
      }
      if (metric.values.avg !== undefined && metric.values.avg !== null) {
        output += indent + `  avg: ${metric.values.avg.toFixed(2)}\n`;
      }
      if (metric.values.max !== undefined && metric.values.max !== null) {
        output += indent + `  max: ${metric.values.max.toFixed(2)}\n`;
      }
      if (metric.values.p95 !== undefined && metric.values.p95 !== null) {
        output += indent + `  p95: ${metric.values.p95.toFixed(2)}\n`;
      }
      if (metric.values.p99 !== undefined && metric.values.p99 !== null) {
        output += indent + `  p99: ${metric.values.p99.toFixed(2)}\n`;
      }
    }
  }

  return output;
}
