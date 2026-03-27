# Secrets Troubleshooting

Secret 관리, External Secrets Operator 관련 문제.

---

## 1. PostgreSQL Password Race Condition

### 문제

```
psycopg2.OperationalError: FATAL: password authentication failed for user "postgres"
```

PostgreSQL Pod가 정상 Running이지만 Application Pod에서 DB 연결 실패.

### 원인

PostgreSQL `initdb`는 최초 실행 시 환경변수의 password로 계정을 생성한다. 이후 환경변수를 변경해도 DB 내부 password는 변경되지 않는다.

기존 흐름:
1. Kustomize가 `base/secret.yaml`의 placeholder를 배포
2. PostgreSQL Pod가 placeholder password로 `initdb` 실행
3. ExternalSecret이 GCP Secret Manager에서 실제 password를 가져와 덮어씀
4. PostgreSQL 내부 password와 Secret 값 불일치

### 해결

**ExternalSecret을 Single Source of Truth로 설정:**

**파일**: `k8s-manifests/overlays/gcp/kustomization.yaml`

```yaml
patches:
  - patch: |-
      $patch: delete
      apiVersion: v1
      kind: Secret
      metadata:
        name: app-secrets
    target:
      kind: Secret
      name: app-secrets
```

**파일**: `k8s-manifests/overlays/gcp/external-secrets/app-secrets.yaml`

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"  # 다른 리소스보다 먼저 생성
```

**파일**: `k8s-manifests/overlays/gcp/postgres/statefulset.yaml`

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # ExternalSecret 이후 생성
```

### 검증

```bash
$ kubectl get secret prod-app-secrets -n titanium-prod -o jsonpath="{.metadata.ownerReferences[0].kind}"
ExternalSecret
```

---

## 6. ExternalSecret Operator CRD/Webhook 오류

### 문제

```
error: unable to recognize "externalsecret.yaml": no matches for kind "ExternalSecret" in version "external-secrets.io/v1beta1"
```

또는

```
Internal error occurred: failed calling webhook "validate.externalsecret.external-secrets.io"
```

### 원인

1. ExternalSecret CRD가 설치되지 않음
2. cert-controller가 비활성화되어 Webhook TLS 인증서 미생성

### 해결

**파일**: `apps/infrastructure/external-secrets-operator.yaml`

```yaml
helm:
  values: |
    installCRDs: true
    certController:
      create: true
    webhook:
      create: true
```

ArgoCD Application에 Sync Wave 추가:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-5"
```

### 검증

```bash
$ kubectl get crd | grep external-secrets
externalsecrets.external-secrets.io    2026-02-02T09:14:54Z
secretstores.external-secrets.io       2026-02-02T09:14:54Z

$ kubectl get externalsecret -n titanium-prod
NAME               STORE                      REFRESH INTERVAL   STATUS
prod-app-secrets   prod-gcpsm-secret-store    1h                 SecretSynced
```

---

## 8. Kustomize namePrefix Secret 참조 오류

### 문제

```
CreateContainerConfigError: secret "app-secrets" not found
```

### 원인

Kustomize `$patch: delete`로 base Secret을 제거하면, 해당 Secret에 대한 `namePrefix` 변환도 적용되지 않는다. Pod의 `secretKeyRef`가 `app-secrets`를 참조하지만, 실제 Secret 이름은 `prod-app-secrets`.

### 해결

**파일**: `k8s-manifests/overlays/gcp/kustomization.yaml`

```yaml
patches:
  - patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/env/0/valueFrom/secretKeyRef/name
        value: prod-app-secrets
    target:
      kind: Deployment
      name: redis-deployment
```

### 검증

```bash
$ kubectl get pods -n titanium-prod --no-headers | grep Running | wc -l
12
```
