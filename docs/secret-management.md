# Secret Management 운영 절차

## 개요

GCP Secret Manager와 External Secrets Operator(ESO)를 사용하여 Kubernetes Secret을 관리한다.
인증 방식은 GCE Application Default Credentials(ADC)를 사용하며, SA Key JSON 파일을 별도로 관리하지 않는다.

## 인증 구조

```
GCE VM (k3s Node)
  └─ Service Account: titanium-k3s-sa
       └─ IAM Role: roles/secretmanager.secretAccessor
            └─ GCE Metadata Server (ADC)
                 └─ ESO ClusterSecretStore (auth 블록 없음 → ADC 자동 사용)
                      └─ ExternalSecret → Kubernetes Secret
```

- `ClusterSecretStore`에 `auth` 블록이 없으면 ESO는 Pod가 실행되는 Node의 GCE Metadata Server를 통해 ADC를 자동으로 사용한다.
- SA Key JSON 파일 생성, 배포, Rotation이 불필요하다.

## 관리 대상 Secret 목록

| Secret ID | 용도 |
|---|---|
| `titanium-jwt-private-key` | JWT 서명용 Private Key |
| `titanium-jwt-public-key` | JWT 검증용 Public Key |
| `titanium-internal-api-secret` | 내부 Service 간 API 인증 |
| `titanium-postgres-user` | PostgreSQL 사용자명 |
| `titanium-postgres-password` | PostgreSQL 비밀번호 |
| `titanium-jwt-secret-key` | JWT HMAC Secret Key |
| `titanium-redis-password` | Redis 비밀번호 |

## Bootstrap 절차

Terraform은 Secret Manager의 **껍데기(Secret Resource)**만 생성한다.
실제 Secret 값(Version)은 `terraform apply` 이후 수동으로 등록해야 한다.

### 1단계: Infrastructure 배포

```bash
cd terraform/environments/gcp
terraform apply
```

### 2단계: Secret 초기값 등록

```bash
# 각 Secret에 대해 초기값을 등록한다
echo -n "실제값" | gcloud secrets versions add titanium-postgres-password --data-file=-
echo -n "실제값" | gcloud secrets versions add titanium-postgres-user --data-file=-
echo -n "실제값" | gcloud secrets versions add titanium-redis-password --data-file=-
echo -n "실제값" | gcloud secrets versions add titanium-jwt-secret-key --data-file=-
echo -n "실제값" | gcloud secrets versions add titanium-internal-api-secret --data-file=-

# RSA Key Pair 생성 및 등록 (JWT 서명용)
openssl genrsa -out /tmp/jwt-private.pem 2048
openssl rsa -in /tmp/jwt-private.pem -pubout -out /tmp/jwt-public.pem
gcloud secrets versions add titanium-jwt-private-key --data-file=/tmp/jwt-private.pem
gcloud secrets versions add titanium-jwt-public-key --data-file=/tmp/jwt-public.pem
rm /tmp/jwt-private.pem /tmp/jwt-public.pem
```

### 3단계: ESO 동기화 확인

k3s Bootstrap 완료 후 ESO가 Secret을 동기화했는지 확인한다.

```bash
kubectl get externalsecrets -A
kubectl get clustersecretstore prod-gcpsm-secret-store
```

## Secret Rotation 절차

1. 새 Secret Version을 추가한다.
   ```bash
   echo -n "새로운값" | gcloud secrets versions add titanium-postgres-password --data-file=-
   ```
2. ESO가 `refreshInterval`에 따라 자동으로 새 값을 동기화한다.
3. 동기화 확인 후 이전 Version을 비활성화한다.
   ```bash
   gcloud secrets versions disable titanium-postgres-password --version=1
   ```

## Troubleshooting

### ESO가 Secret을 가져오지 못하는 경우

1. ClusterSecretStore 상태 확인:
   ```bash
   kubectl describe clustersecretstore prod-gcpsm-secret-store
   ```
2. IAM Binding 확인:
   ```bash
   gcloud projects get-iam-policy PROJECT_ID \
     --flatten="bindings[].members" \
     --filter="bindings.role:roles/secretmanager.secretAccessor"
   ```
3. Secret Version 존재 여부 확인:
   ```bash
   gcloud secrets versions list titanium-postgres-password
   ```
