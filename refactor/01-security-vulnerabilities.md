# Security Vulnerabilities

이 문서는 인프라 코드에서 발견된 보안 취약점과 해결 방법을 상세히 기술한다.

---

## 목차

1. [SEC-001: CORS Wildcard 설정](#sec-001-cors-wildcard-설정)
2. [SEC-002: Istio Gateway HTTP Only](#sec-002-istio-gateway-http-only)
3. [SEC-003: RBAC/NetworkPolicy 부재](#sec-003-rbacnetworkpolicy-부재)
4. [SEC-004: PostgreSQL SSL 비활성화](#sec-004-postgresql-ssl-비활성화)
5. [SEC-005: Firewall 0.0.0.0/0 개방](#sec-005-firewall-00000-개방)
6. [SEC-006: kubeconfig TLS 검증 비활성화](#sec-006-kubeconfig-tls-검증-비활성화)

---

## SEC-001: CORS Wildcard 설정

### 위험도: High

### 문제

**파일**: `k8s-manifests/overlays/gcp/configmap-patch.yaml:35`

```yaml
# Before (문제 코드)
data:
  CORS_ALLOWED_ORIGINS: "*"
```

모든 Origin에서 Cross-Origin 요청을 허용하면 CSRF(Cross-Site Request Forgery) 공격에 취약해진다.

### 원인

개발 편의를 위해 CORS를 전체 개방했으나, Production 환경에서는 특정 도메인만 허용해야 한다.

### 해결 방법

```yaml
# After (수정 코드)
data:
  CORS_ALLOWED_ORIGINS: "https://titanium.example.com,https://admin.titanium.example.com"
```

실제 서비스 도메인만 명시적으로 허용한다.

### 검증

```bash
# ConfigMap 확인
kubectl get configmap app-config -n titanium-prod -o yaml | grep CORS

# CORS 헤더 테스트
curl -I -X OPTIONS https://api.titanium.example.com/api/users \
  -H "Origin: https://malicious.com" \
  -H "Access-Control-Request-Method: GET"

# 허용되지 않은 Origin은 Access-Control-Allow-Origin 헤더가 없어야 함
```

---

## SEC-002: Istio Gateway HTTP Only

### 위험도: High

### 문제

**파일**: `k8s-manifests/overlays/gcp/istio/gateway.yaml:9-15`

```yaml
# Before (문제 코드)
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
```

모든 트래픽이 암호화되지 않은 HTTP로 전송되어 중간자 공격(MITM)에 취약하다.

### 원인

TLS 인증서 설정 없이 HTTP만 구성되어 있다.

### 해결 방법

**Step 1: cert-manager 설치 (이미 설치되어 있다면 생략)**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

**Step 2: ClusterIssuer 생성**

```yaml
# k8s-manifests/overlays/gcp/istio/cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: istio
```

**Step 3: Certificate 생성**

```yaml
# k8s-manifests/overlays/gcp/istio/certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: titanium-cert
  namespace: istio-system
spec:
  secretName: titanium-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - titanium.example.com
  - "*.titanium.example.com"
```

**Step 4: Gateway 수정**

```yaml
# After (수정 코드)
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: titanium-gateway
  namespace: titanium-prod
spec:
  selector:
    istio: ingressgateway
  servers:
  # HTTPS Server
  - port:
      number: 443
      name: https
      protocol: HTTPS
    hosts:
    - "titanium.example.com"
    tls:
      mode: SIMPLE
      credentialName: titanium-tls
  # HTTP to HTTPS Redirect
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "titanium.example.com"
    tls:
      httpsRedirect: true
```

### 검증

```bash
# TLS 인증서 확인
kubectl get certificate -n istio-system

# HTTPS 연결 테스트
curl -v https://titanium.example.com/health

# HTTP Redirect 확인
curl -I http://titanium.example.com/health
# 301 Redirect to HTTPS 응답 확인
```

---

## SEC-003: RBAC/NetworkPolicy 부재

### 위험도: Medium

### 문제

프로젝트에 Kubernetes RBAC(Role, RoleBinding) 및 NetworkPolicy 리소스가 정의되어 있지 않다.

- 모든 Pod가 기본 ServiceAccount로 실행
- Pod 간 네트워크 격리 없음

### 원인

초기 개발 단계에서 접근 제어를 구현하지 않았다.

### 해결 방법

**Step 1: ServiceAccount 생성**

```yaml
# k8s-manifests/overlays/gcp/rbac/serviceaccounts.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-gateway-sa
  namespace: titanium-prod
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: user-service-sa
  namespace: titanium-prod
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: auth-service-sa
  namespace: titanium-prod
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: blog-service-sa
  namespace: titanium-prod
```

**Step 2: Role 및 RoleBinding 생성**

```yaml
# k8s-manifests/overlays/gcp/rbac/roles.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: titanium-app-role
  namespace: titanium-prod
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
  resourceNames: ["app-secrets"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: titanium-app-rolebinding
  namespace: titanium-prod
subjects:
- kind: ServiceAccount
  name: api-gateway-sa
- kind: ServiceAccount
  name: user-service-sa
- kind: ServiceAccount
  name: auth-service-sa
- kind: ServiceAccount
  name: blog-service-sa
roleRef:
  kind: Role
  name: titanium-app-role
  apiGroup: rbac.authorization.k8s.io
```

**Step 3: NetworkPolicy 생성**

```yaml
# k8s-manifests/overlays/gcp/rbac/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: titanium-prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-gateway-ingress
  namespace: titanium-prod
spec:
  podSelector:
    matchLabels:
      app: api-gateway
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: istio-system
    ports:
    - protocol: TCP
      port: 8000
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-internal-services
  namespace: titanium-prod
spec:
  podSelector:
    matchLabels:
      project: titanium
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          project: titanium
  egress:
  - to:
    - podSelector:
        matchLabels:
          project: titanium
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
```

**Step 4: Deployment에 ServiceAccount 적용**

```yaml
# k8s-manifests/overlays/gcp/patches/serviceaccount-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway-deployment
spec:
  template:
    spec:
      serviceAccountName: api-gateway-sa
```

### 검증

```bash
# ServiceAccount 확인
kubectl get sa -n titanium-prod

# Role/RoleBinding 확인
kubectl get role,rolebinding -n titanium-prod

# NetworkPolicy 확인
kubectl get networkpolicy -n titanium-prod

# Pod 권한 테스트 (ServiceAccount 토큰으로)
kubectl exec -it <pod-name> -n titanium-prod -- \
  curl -k https://kubernetes.default.svc/api/v1/namespaces/titanium-prod/pods
# 403 Forbidden 응답 확인 (불필요한 API 접근 차단)
```

---

## SEC-004: PostgreSQL SSL 비활성화

### 위험도: Medium

### 문제

**파일**: `k8s-manifests/overlays/gcp/kustomization.yaml:80`

```yaml
# Before (문제 코드)
configMapGenerator:
  - name: app-config
    literals:
      - POSTGRES_SSLMODE=disable
```

데이터베이스 연결이 암호화되지 않아 내부 네트워크에서도 데이터 노출 위험이 있다.

### 원인

Istio mTLS가 적용되어 있어 별도 SSL 설정을 생략했으나, Defense in Depth 원칙에 따라 다중 암호화가 권장된다.

### 해결 방법

**Step 1: PostgreSQL SSL 인증서 생성**

```bash
# Self-signed 인증서 생성
openssl req -new -x509 -days 365 -nodes \
  -out server.crt -keyout server.key \
  -subj "/CN=postgresql-service"

# Secret 생성
kubectl create secret tls postgres-tls \
  -n titanium-prod \
  --cert=server.crt \
  --key=server.key
```

**Step 2: PostgreSQL StatefulSet 수정**

```yaml
# k8s-manifests/overlays/gcp/postgres/statefulset.yaml
spec:
  containers:
  - name: postgres
    args:
    - "-c"
    - "ssl=on"
    - "-c"
    - "ssl_cert_file=/var/lib/postgresql/ssl/tls.crt"
    - "-c"
    - "ssl_key_file=/var/lib/postgresql/ssl/tls.key"
    volumeMounts:
    - name: postgres-tls
      mountPath: /var/lib/postgresql/ssl
      readOnly: true
  volumes:
  - name: postgres-tls
    secret:
      secretName: postgres-tls
      defaultMode: 0600
```

**Step 3: Application 설정 변경**

```yaml
# After (수정 코드)
configMapGenerator:
  - name: app-config
    literals:
      - POSTGRES_SSLMODE=require
```

### 검증

```bash
# PostgreSQL SSL 상태 확인
kubectl exec -it postgres-0 -n titanium-prod -- \
  psql -U postgres -c "SHOW ssl;"

# 연결 테스트
kubectl exec -it <app-pod> -n titanium-prod -- \
  python -c "import psycopg2; conn = psycopg2.connect(sslmode='require'); print('SSL OK')"
```

---

## SEC-005: Firewall 0.0.0.0/0 개방

### 위험도: High

### 문제

**파일**: `terraform/modules/instance/variables.tf:39-55`

```hcl
# Before (문제 코드)
variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to access SSH (port 22)"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # 전체 인터넷에 SSH 개방
}

variable "allowed_k8s_cidrs" {
  description = "List of CIDR blocks allowed to access Kubernetes API (port 6443)"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # 전체 인터넷에 K8s API 개방
}
```

CloudStack 모듈에서 SSH(22)와 Kubernetes API(6443) 포트가 전체 인터넷에 개방되어 있다.

### 원인

개발 편의를 위해 기본값을 0.0.0.0/0으로 설정했다.

### 해결 방법

**Step 1: 변수 기본값 제거**

```hcl
# After (수정 코드)
variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to access SSH (port 22). Must be explicitly set."
  type        = list(string)
  # 기본값 없음 - 반드시 명시적으로 설정해야 함

  validation {
    condition     = length(var.allowed_ssh_cidrs) > 0
    error_message = "At least one CIDR block must be specified for SSH access."
  }

  validation {
    condition     = !contains(var.allowed_ssh_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed. Specify restricted CIDR blocks."
  }
}

variable "allowed_k8s_cidrs" {
  description = "List of CIDR blocks allowed to access Kubernetes API (port 6443). Must be explicitly set."
  type        = list(string)

  validation {
    condition     = length(var.allowed_k8s_cidrs) > 0
    error_message = "At least one CIDR block must be specified for K8s API access."
  }

  validation {
    condition     = !contains(var.allowed_k8s_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed. Specify restricted CIDR blocks."
  }
}
```

**Step 2: tfvars에서 명시적 설정**

```hcl
# terraform.tfvars
allowed_ssh_cidrs = ["203.0.113.0/24"]  # 회사 IP 대역
allowed_k8s_cidrs = ["203.0.113.0/24"]  # 회사 IP 대역
```

### 검증

```bash
# Terraform plan 실행 - validation 확인
terraform plan

# 0.0.0.0/0 사용 시 에러 발생 확인
# Error: 0.0.0.0/0 is not allowed. Specify restricted CIDR blocks.

# 방화벽 규칙 확인 (CloudStack)
cloudmonkey list firewallrules
```

---

## SEC-006: kubeconfig TLS 검증 비활성화

### 위험도: Medium

### 문제

**파일**: `terraform/environments/gcp/main.tf:262`

```yaml
# Before (문제 코드)
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: https://${google_compute_address.master_external_ip.address}:6443
  name: gcp-k3s
```

TLS 인증서 검증을 비활성화하면 중간자 공격(MITM)에 취약해진다.

### 원인

k3s 자체 서명 인증서를 사용하며, 인증서 복사 과정을 생략하기 위해 설정했다.

### 해결 방법

**Step 1: k3s CA 인증서 추출 스크립트 추가**

```bash
# terraform/environments/gcp/scripts/get-kubeconfig.sh
#!/bin/bash
MASTER_IP=$1
SSH_KEY=${2:-~/.ssh/id_rsa}

# k3s.yaml 복사
ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$MASTER_IP \
  "sudo cat /etc/rancher/k3s/k3s.yaml" > ~/.kube/config-gcp-secure

# 서버 주소 변경
sed -i '' "s/127.0.0.1/$MASTER_IP/g" ~/.kube/config-gcp-secure

echo "Secure kubeconfig created at ~/.kube/config-gcp-secure"
```

**Step 2: Terraform output 추가**

```hcl
# terraform/environments/gcp/outputs.tf
output "kubeconfig_command" {
  description = "Command to get secure kubeconfig"
  value       = "./scripts/get-kubeconfig.sh ${google_compute_address.master_external_ip.address}"
}
```

**Step 3: null_resource 수정**

```hcl
# After (수정 코드)
resource "null_resource" "create_kubeconfig" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Run the following command after k3s bootstrap completes (~5-10 min):"
      echo "./scripts/get-kubeconfig.sh ${google_compute_address.master_external_ip.address}"
    EOT
  }
}
```

### 검증

```bash
# Secure kubeconfig 생성
./scripts/get-kubeconfig.sh <MASTER_IP>

# 연결 테스트
KUBECONFIG=~/.kube/config-gcp-secure kubectl get nodes

# TLS 검증 확인
kubectl config view --raw | grep -A5 "cluster:"
# insecure-skip-tls-verify가 없고 certificate-authority-data가 있어야 함
```

---

## 요약

| ID | 항목 | 위험도 | 난이도 | 예상 시간 |
|----|------|--------|--------|-----------|
| SEC-001 | CORS Wildcard | High | Low | 1시간 |
| SEC-002 | HTTPS 미적용 | High | Medium | 4시간 |
| SEC-003 | RBAC/NetworkPolicy | Medium | Medium | 4시간 |
| SEC-004 | PostgreSQL SSL | Medium | Medium | 2시간 |
| SEC-005 | Firewall 0.0.0.0/0 | High | Low | 1시간 |
| SEC-006 | TLS 검증 비활성화 | Medium | Low | 2시간 |
