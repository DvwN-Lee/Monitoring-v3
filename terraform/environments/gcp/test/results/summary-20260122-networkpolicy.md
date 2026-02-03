# NetworkPolicy E2E Test Results

**Date**: 2026-01-22
**PR**: #75 (Blog Service -> Auth Service NetworkPolicy)
**Tester**: Automated E2E Test

---

## Test Summary

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Cluster Access via IAP Tunnel | PASS |
| 2 | Test User Creation | PASS |
| 3 | E2E API Tests | PASS |
| 4 | Result Documentation | PASS |

---

## Test Environment

- **Cluster**: titanium-k3s (GCP asia-northeast3-a)
- **Namespace**: titanium-prod
- **Blog Service Pod**: prod-blog-service-deployment-65c765588f-j2827
- **Auth Service Pod**: prod-auth-service-deployment-bb54c674f-2vlkd

---

## E2E Test Results

### [1] Login Test (Auth Service)

```
Status: 200 OK
Token: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VyX2lkI...
```

**Verification**: Blog Service -> Auth Service 통신 정상

### [2] Create Post Test (Blog Service with Auth)

```
Status: 201 Created
Post ID: 1
Response: {
  'id': 1,
  'title': 'NetworkPolicy E2E Test Post',
  'content': '<p>This post verifies Blog-Auth NetworkPolicy.</p>',
  'author': 'e2e_np_test',
  'created_at': '2026-01-22T05:16:21.040658',
  'category': {'id': 4, 'name': 'technology', 'slug': 'technology'}
}
```

**Verification**: JWT 토큰 검증을 위한 Blog -> Auth 통신 정상

### [3] Get Post Test (Verify Creation)

```
Status: 200 OK
```

### [4] Delete Post Test

```
Status: 204 Deleted
```

---

## NetworkPolicy Verification

PR #75에서 추가된 NetworkPolicy 규칙이 정상 작동함을 확인:

1. **Blog Service -> Auth Service (TCP 8002)**: PASS
   - 로그인 API 호출 성공
   - JWT 토큰 발급 정상

2. **Blog Service -> Auth Service Token Validation**: PASS
   - CRUD 작업 시 Auth Service로 토큰 검증 요청 성공
   - 502 Bad Gateway 오류 없음

---

## Conclusion

PR #75 merge 후 NetworkPolicy 변경 사항이 의도한 대로 작동합니다.
Blog Service에서 Auth Service로의 egress 트래픽이 정상적으로 허용되며,
JWT 기반 인증이 정상 동작합니다.
