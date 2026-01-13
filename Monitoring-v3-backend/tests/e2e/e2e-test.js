import http from 'k6/http';
import { check, sleep } from 'k6';
import { randomString } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';

// E2E Test Configuration
export const options = {
  vus: 1, // Single user for E2E scenario
  iterations: 1, // Run once
  thresholds: {
    checks: ['rate>0.9'], // 90% of checks should pass
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://10.0.11.168:31304';

export default function () {
  console.log('=== E2E User Journey Test ===');

  // Scenario 1: Unauthenticated User
  console.log('Scenario 1: Unauthenticated User');

  // Test 1.1: Blog Main Page
  console.log('Test 1.1: Blog Main Page');
  let blogRes = http.get(`${BASE_URL}/blog/`);
  check(blogRes, {
    'E2E-1.1: Blog main page returns 200': (r) => r.status === 200,
  });
  sleep(1);

  // Test 1.2: Posts List
  console.log('Test 1.2: Posts List API');
  let postsRes = http.get(`${BASE_URL}/blog/api/posts`);
  check(postsRes, {
    'E2E-1.2: Posts list returns 200': (r) => r.status === 200,
    'E2E-1.2: Posts list returns array': (r) => {
      try {
        return Array.isArray(JSON.parse(r.body));
      } catch (e) {
        return false;
      }
    },
  });
  sleep(1);

  // Test 1.3: Categories
  console.log('Test 1.3: Categories API');
  let categoriesRes = http.get(`${BASE_URL}/blog/api/categories`);
  check(categoriesRes, {
    'E2E-1.3: Categories returns 200': (r) => r.status === 200,
  });
  sleep(1);

  // Test 1.4: Unauthenticated Post Creation (should fail)
  console.log('Test 1.4: Unauthenticated Post Creation');
  let unauthorizedPostRes = http.post(
    `${BASE_URL}/blog/api/posts`,
    JSON.stringify({
      title: 'Test Post',
      content: 'Test content',
      category_id: 1,
    }),
    {
      headers: { 'Content-Type': 'application/json' },
    }
  );
  check(unauthorizedPostRes, {
    'E2E-1.4: Unauthenticated post creation returns 401': (r) => r.status === 401,
  });
  sleep(1);

  // Scenario 2: Authenticated User Journey
  console.log('Scenario 2: Authenticated User Journey');

  // Test 2.1: User Registration
  console.log('Test 2.1: User Registration');
  const testUsername = `testuser_${randomString(8)}`;
  const testEmail = `${testUsername}@example.com`;
  const testPassword = 'TestPassword123!';

  let registerRes = http.post(
    `${BASE_URL}/api/register`,
    JSON.stringify({
      username: testUsername,
      email: testEmail,
      password: testPassword,
    }),
    {
      headers: { 'Content-Type': 'application/json' },
    }
  );

  let registrationSuccess = check(registerRes, {
    'E2E-2.1: User registration returns 201': (r) => r.status === 201,
  });

  if (!registrationSuccess) {
    console.log('Registration failed, skipping authenticated tests');
    return;
  }
  sleep(1);

  // Test 2.2: Login
  console.log('Test 2.2: Login');
  let loginRes = http.post(
    `${BASE_URL}/api/login`,
    JSON.stringify({
      username: testUsername,
      password: testPassword,
    }),
    {
      headers: { 'Content-Type': 'application/json' },
    }
  );

  let token = null;
  let loginSuccess = check(loginRes, {
    'E2E-2.2: Login returns 200': (r) => r.status === 200,
    'E2E-2.2: Login returns token': (r) => {
      try {
        const body = JSON.parse(r.body);
        token = body.token || body.access_token;
        return token !== null && token !== undefined;
      } catch (e) {
        return false;
      }
    },
  });

  if (!loginSuccess || !token) {
    console.log('Login failed or no token received, skipping authenticated tests');
    return;
  }
  sleep(1);

  // Test 2.3: Create Post
  console.log('Test 2.3: Create Post');
  let createPostRes = http.post(
    `${BASE_URL}/blog/api/posts`,
    JSON.stringify({
      title: 'E2E Test Post',
      content: 'This is a test post created by E2E test',
      category_id: 1,
    }),
    {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
      },
    }
  );

  let postId = null;
  let createSuccess = check(createPostRes, {
    'E2E-2.3: Create post returns 201': (r) => r.status === 201,
    'E2E-2.3: Create post returns post ID': (r) => {
      try {
        const body = JSON.parse(r.body);
        postId = body.id;
        return postId !== null && postId !== undefined;
      } catch (e) {
        return false;
      }
    },
  });

  if (!createSuccess || !postId) {
    console.log('Post creation failed, skipping update/delete tests');
    return;
  }
  sleep(1);

  // Test 2.4: Read Created Post
  console.log('Test 2.4: Read Created Post');
  let readPostRes = http.get(`${BASE_URL}/blog/api/posts/${postId}`);
  check(readPostRes, {
    'E2E-2.4: Read post returns 200': (r) => r.status === 200,
    'E2E-2.4: Read post returns correct title': (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.title === 'E2E Test Post';
      } catch (e) {
        return false;
      }
    },
  });
  sleep(1);

  // Test 2.5: Update Post
  console.log('Test 2.5: Update Post');
  let updatePostRes = http.patch(
    `${BASE_URL}/blog/api/posts/${postId}`,
    JSON.stringify({
      title: 'Updated E2E Test Post',
      content: 'This post was updated by E2E test',
    }),
    {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
      },
    }
  );
  check(updatePostRes, {
    'E2E-2.5: Update post returns 200': (r) => r.status === 200,
  });
  sleep(1);

  // Test 2.6: Delete Post
  console.log('Test 2.6: Delete Post');
  let deletePostRes = http.del(
    `${BASE_URL}/blog/api/posts/${postId}`,
    null,
    {
      headers: {
        'Authorization': `Bearer ${token}`,
      },
    }
  );
  check(deletePostRes, {
    'E2E-2.6: Delete post returns 204': (r) => r.status === 204,
  });
  sleep(1);

  // Test 2.7: Verify Post Deleted
  console.log('Test 2.7: Verify Post Deleted');
  let verifyDeleteRes = http.get(`${BASE_URL}/blog/api/posts/${postId}`);
  check(verifyDeleteRes, {
    'E2E-2.7: Deleted post returns 404': (r) => r.status === 404,
  });

  console.log('=== E2E User Journey Test Completed ===');
}
