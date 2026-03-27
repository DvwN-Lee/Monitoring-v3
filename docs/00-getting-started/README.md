# Getting Started

## 프로젝트 배경

Monitoring-v2는 Solid Cloud의 Managed Kubernetes 위에서 운영되었으나, Infrastructure 자동화 범위가 Namespace 이하로 제한되었다. v3는 GCP IaaS 위에 K3s를 직접 구성하여, VM 생성부터 Application 배포까지 단일 `terraform apply`로 완료되는 End-to-End 자동화를 목표로 한다.

### 핵심 Architecture 요약

- **Infrastructure**: GCP Compute Engine + K3s v1.31.4+k3s1, Istio 1.24.2, Terraform으로 전체 리소스 코드화
- **배포**: ArgoCD App of Apps 패턴 기반 GitOps, GitHub Actions CI/CD Pipeline
- **보안**: Istio mTLS(STRICT), Zero Trust NetworkPolicy, External Secrets + GCP Secret Manager

## 사전 요구사항

| 도구 | 최소 버전 | 용도 |
|------|----------|------|
| Terraform | >= 1.5 | Infrastructure 배포 |
| Google Cloud SDK | 최신 | GCP 인증 및 리소스 관리 |
| kubectl | >= 1.28 | Kubernetes Cluster 제어 |
| SSH Key Pair | RSA 4096 | VM 접근용 |

### GCP 프로젝트 설정

```bash
# GCP 인증
gcloud auth login
gcloud auth application-default login

# 프로젝트 설정
gcloud config set project <YOUR_PROJECT_ID>
gcloud config set compute/region asia-northeast3
```

### SSH 키 생성

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/titanium-key -N "" -C "titanium-k3s-cluster"
```

## Infrastructure 배포

### 1. Terraform 변수 설정

```bash
cd terraform/environments/gcp

cat > terraform.tfvars << 'EOF'
project_id          = "your-gcp-project-id"
ssh_public_key_path = "~/.ssh/titanium-key.pub"

# Dashboard 직접 접근을 허용할 IP (선택)
admin_cidrs = ["YOUR_IP/32"]
EOF
```

### 2. 민감 변수 설정

Secret은 환경변수로 전달한다. 코드에 직접 기입하지 않는다.

```bash
export TF_VAR_postgres_password="your-secure-password"
export TF_VAR_grafana_admin_password="your-grafana-password"
```

### 3. 배포 실행

```bash
terraform init
terraform plan    # 리소스 변경 사항 사전 확인
terraform apply   # 승인 후 배포
```

### 4. 자동 구성 흐름

`terraform apply` 완료 후 약 10분 내에 다음이 순차적으로 진행된다.

```
1. GCP VM 생성 (Master + Workers)
2. K3s Cluster 설치 (Bootstrap Script)
3. ArgoCD 설치 및 Root App 등록
4. Infrastructure Apps Sync (Istio, Prometheus, Loki, Kiali, External Secrets)
5. Application Apps Sync (titanium-prod namespace)
6. External Secrets → GCP Secret Manager 연동
```

### 5. 접속 정보 확인

```bash
# Master IP 확인
terraform output master_external_ip

# ArgoCD 초기 Password 확인
ssh -i ~/.ssh/titanium-key ubuntu@<MASTER_IP> \
  "sudo kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
```

| Service | URL | 인증 |
|---------|-----|------|
| Blog Application | `http://<MASTER_IP>:31080/blog/` | 자체 회원가입/로그인 |
| ArgoCD | `http://<MASTER_IP>:30080` | admin / 위 명령어로 확인 |
| Grafana | `http://<MASTER_IP>:31300/grafana/` | admin / TF_VAR_grafana_admin_password |
| Kiali | `http://<MASTER_IP>:31200/kiali/` | 인증 없음 |

`admin_cidrs` 미설정 시 SSH 터널을 통해 접근한다.

```bash
gcloud compute ssh titanium-k3s-master --tunnel-through-iap \
  -- -L 30080:localhost:30080 -L 31080:localhost:31080 -L 31200:localhost:31200 -L 31300:localhost:31300
```

## 첫 배포 후 검증 Checklist

### Infrastructure 확인

```bash
# K3s Node 상태
ssh -i ~/.ssh/titanium-key ubuntu@<MASTER_IP> "sudo kubectl get nodes"
# 기대: 1 master + 2 workers, Ready 상태

# Namespace 확인
ssh -i ~/.ssh/titanium-key ubuntu@<MASTER_IP> "sudo kubectl get ns"
# 기대: argocd, istio-system, monitoring, titanium-prod, external-secrets
```

### ArgoCD Application 동기화 확인

```bash
ssh -i ~/.ssh/titanium-key ubuntu@<MASTER_IP> \
  "sudo kubectl get app -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'"
# 기대: 9개 Application 모두 Synced / Healthy
```

### Application Pod 상태 확인

```bash
ssh -i ~/.ssh/titanium-key ubuntu@<MASTER_IP> \
  "sudo kubectl get pods -n titanium-prod"
# 기대: 모든 Pod Running, 2/2 (app + istio-proxy sidecar)
```

### Service 정상 동작 확인

```bash
# Blog Application 접속
curl -s -o /dev/null -w "%{http_code}" http://<MASTER_IP>:31080/blog/
# 기대: 200

# Health Check
curl -s http://<MASTER_IP>:31080/api/users/health
# 기대: {"status":"healthy"}
```

### Secret 연동 확인

```bash
ssh -i ~/.ssh/titanium-key ubuntu@<MASTER_IP> \
  "sudo kubectl get externalsecret -n titanium-prod"
# 기대: STATUS = SecretSynced
```

## 리소스 제거

```bash
terraform destroy
```

## 다음 단계

- [Architecture](../architecture/README.md): 시스템 아키텍처 상세 이해
- [Operations Guide](../03-operations/guides/operations-guide.md): 일상 운영 절차
- [Troubleshooting](../04-troubleshooting/README.md): 문제 발생 시 해결 가이드
