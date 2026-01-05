# GCP Overlay

GCP k3s Cluster Production 환경을 위한 Kustomize overlay 설정입니다.

## 환경 정보

| 항목 | 값 |
|------|-----|
| **GCP Project ID** | `titanium-k3s-1765951764` |
| **Region** | `asia-northeast3` (서울) |
| **Zone** | `asia-northeast3-a` |
| **Cluster Name** | `titanium-k3s` |
| **Namespace** | `titanium-prod` |

## 배포 방법

### 1. Kubeconfig 설정

GCP k3s Master Node에서 kubeconfig를 가져옵니다:

```bash
# Master Node에 SSH 접속
gcloud compute ssh titanium-k3s-master --zone=asia-northeast3-a

# Kubeconfig 복사
sudo cat /etc/rancher/k3s/k3s.yaml
```

로컬 머신에 kubeconfig 저장:

```bash
# ~/.kube/config-gcp 파일에 저장
# server 주소를 Master Node의 External IP로 변경
```

### 2. Secret 파일 생성

`secret-patch.yaml.example`을 복사하여 실제 Secret 값을 입력합니다:

```bash
cd k8s-manifests/overlays/gcp
cp secret-patch.yaml.example secret-patch.yaml
```

`secret-patch.yaml` 파일에서 다음 값들을 Base64 인코딩하여 입력:

```bash
# PostgreSQL 비밀번호 인코딩
echo -n 'your-password' | base64

# JWT Secret 인코딩
echo -n 'your-jwt-secret' | base64
```

**주의**: `secret-patch.yaml`은 `.gitignore`에 포함되어 있으므로 Git에 commit되지 않습니다.

### 3. 배포 실행

**수동 배포**:

```bash
export KUBECONFIG=~/.kube/config-gcp
kubectl apply -k k8s-manifests/overlays/gcp/
```

**ArgoCD를 통한 자동 배포**:

ArgoCD Application이 Git repository의 변경사항을 감지하여 자동으로 배포합니다. 별도 작업이 필요하지 않습니다.

## Service 접속 정보

GCP k3s Cluster의 Master Node External IP를 확인:

```bash
gcloud compute instances describe titanium-k3s-master \
  --zone=asia-northeast3-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

### Dashboard 및 Monitoring

| Service | NodePort | URL 형식 |
|---------|----------|----------|
| **ArgoCD** | 30080 | `http://<MASTER_IP>:30080` |
| **Grafana** | 31300 | `http://<MASTER_IP>:31300` |
| **Prometheus** | 31090 | `http://<MASTER_IP>:31090` |
| **Kiali** | 31200 | `http://<MASTER_IP>:31200` |

### Application Service

| Service | NodePort | URL 형식 |
|---------|----------|----------|
| **Istio Ingress Gateway (HTTP)** | 31080 | `http://<MASTER_IP>:31080` |
| **Istio Ingress Gateway (HTTPS)** | 31443 | `https://<MASTER_IP>:31443` |

Application endpoints (Istio Gateway를 통해):

- User Service: `http://<MASTER_IP>:31080/api/users`
- Blog Service: `http://<MASTER_IP>:31080/api/blogs`
- Auth Service: `http://<MASTER_IP>:31080/api/auth`

## 설정 파일 구조

```
gcp/
├── kustomization.yaml           # Kustomize 설정
├── namespace.yaml               # Namespace 정의
├── configmap-patch.yaml         # ConfigMap override
├── secret-patch.yaml.example    # Secret template
├── hpa.yaml                     # Horizontal Pod Autoscaler
├── load-generator.yaml          # 부하 테스트용 Pod
├── istio/                       # Istio 설정
│   ├── gateway.yaml
│   ├── peer-authentication.yaml
│   ├── peer-authentication-databases.yaml
│   └── destination-rules.yaml
└── patches/                     # Deployment patches
    ├── user-service-deployment-patch.yaml
    ├── blog-service-deployment-patch.yaml
    ├── auth-service-deployment-patch.yaml
    └── service-lb-patch.yaml
```

## Image 관리

Docker Hub registry (`dongju101`)를 사용합니다. Image tag는 GitHub Actions CD pipeline에서 자동으로 업데이트됩니다.

현재 설정된 Image:

- `dongju101/user-service`
- `dongju101/blog-service`
- `dongju101/auth-service`
- `dongju101/api-gateway`

## Troubleshooting

### Pod가 시작되지 않는 경우

```bash
export KUBECONFIG=~/.kube/config-gcp
kubectl get pods -n titanium-prod
kubectl describe pod <POD_NAME> -n titanium-prod
kubectl logs <POD_NAME> -n titanium-prod
```

### ArgoCD Sync 실패

```bash
# ArgoCD Application 상태 확인
kubectl get application titanium-prod -n argocd

# ArgoCD Pod 로그 확인
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

### Service 연결 실패

```bash
# Service 확인
kubectl get svc -n titanium-prod

# Istio Gateway 상태 확인
kubectl get gateway -n titanium-prod
kubectl get virtualservice -n titanium-prod
```

## HTTPS/TLS 설정

Istio Gateway는 HTTPS (port 443)를 지원합니다. Self-signed 인증서를 사용한 설정 방법:

### 1. TLS 인증서 생성

```bash
# 스크립트 실행
./scripts/generate-tls-cert.sh

# 또는 수동으로 생성
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=titanium.local/O=Titanium"

kubectl create secret tls titanium-tls-credential \
  --key=tls.key --cert=tls.crt \
  -n istio-system
```

### 2. HTTPS 접속 테스트

```bash
# Self-signed 인증서이므로 -k 옵션 사용
curl -k https://<MASTER_IP>:31443/health

# HTTP 요청은 HTTPS로 redirect됨
curl -I http://<MASTER_IP>:31080/
```

### 3. TLS Secret 확인

```bash
kubectl get secret titanium-tls-credential -n istio-system
kubectl describe secret titanium-tls-credential -n istio-system
```

## Production 인증서 (cert-manager + Let's Encrypt)

Self-signed 인증서 대신 Let's Encrypt를 통한 자동 인증서 발급을 권장합니다.

### 1. cert-manager 설치

```bash
# cert-manager CRD 및 Controller 설치
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# 설치 확인
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s
```

### 2. ClusterIssuer 생성 (Let's Encrypt)

```yaml
# cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: istio
```

```bash
kubectl apply -f cluster-issuer.yaml
```

### 3. Certificate 리소스 생성

```yaml
# certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: titanium-tls
  namespace: istio-system
spec:
  secretName: titanium-tls-credential
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - your-domain.com
  - "*.your-domain.com"
```

```bash
kubectl apply -f certificate.yaml
```

### 4. DNS 설정 요구사항

Let's Encrypt HTTP-01 Challenge를 사용하려면:
- 도메인이 Master Node의 Public IP를 가리켜야 함
- Port 80이 외부에서 접근 가능해야 함

DNS-01 Challenge 사용 시 (Wildcard 인증서):
- GCP Cloud DNS 또는 외부 DNS Provider 연동 필요
- cert-manager DNS Provider 설정 추가 필요

### 5. 자동 갱신

cert-manager는 인증서 만료 30일 전에 자동으로 갱신합니다. 별도 작업이 필요하지 않습니다.

## 보안 고려사항

1. **Secret 관리**: `secret-patch.yaml` 파일을 Git에 commit하지 마세요
2. **Firewall**: GCP Firewall Rule이 필요한 Port만 허용하는지 확인하세요
3. **HTTPS**: Istio Gateway에 TLS 인증서가 설정되어 있습니다 (Self-signed)
4. **Kubeconfig 보안**: Kubeconfig 파일의 권한을 `600`으로 설정하세요
5. **mTLS**: Istio Service Mesh 내부 통신은 mTLS STRICT 모드로 암호화됩니다
6. **cert-manager**: Production 환경에서는 Let's Encrypt 인증서 사용을 권장합니다

## 관련 문서

- [Terraform GCP 환경 설정](../../../terraform/environments/gcp/README.md)
- [프로젝트 전체 가이드](../../../README.md)
