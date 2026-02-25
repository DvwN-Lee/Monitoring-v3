# Application Troubleshooting

Microservice Application 관련 문제.

---

## 9. Redis Password 미설정

### 문제

Redis가 인증 없이 접근 가능하여 보안 취약점 발생.

### 해결

**파일**: `k8s-manifests/base/redis-deployment.yaml`

```yaml
spec:
  containers:
  - name: redis
    env:
    - name: REDIS_PASSWORD
      valueFrom:
        secretKeyRef:
          name: app-secrets
          key: redis-password
    args:
    - "--requirepass"
    - "$(REDIS_PASSWORD)"
```

### 검증

```bash
$ kubectl exec -n titanium-prod deploy/prod-redis-deployment -- redis-cli ping
NOAUTH Authentication required.
```
