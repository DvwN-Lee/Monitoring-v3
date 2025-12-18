# GCP Environment - Complete GitOps Automation

Google Cloud Platform에서 k3s cluster와 ArgoCD를 완전 자동화로 배포하는 Terraform 설정입니다.

## Architecture

- **Provider**: Google Cloud Platform (GCP)
- **Infrastructure**: VPC, Subnet, Firewall, Compute Engine instances
- **Kubernetes**: k3s (1 master + 2 workers)
- **GitOps**: ArgoCD with App of Apps pattern
- **Automation**: Complete bootstrap via startup script

## Prerequisites

1. GCP Project 및 Billing 활성화
2. gcloud CLI 설치 및 인증
3. Terraform >= 1.5.0
4. SSH keypair 생성 (기본: ~/.ssh/id_rsa.pub)

## GCP Setup

### 1. GCP Project 생성 및 API 활성화

```bash
# GCP Project 생성
gcloud projects create YOUR_PROJECT_ID --name="Titanium K3s"

# Project 설정
gcloud config set project YOUR_PROJECT_ID

# 필수 API 활성화
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com
```

### 2. Service Account 생성 및 Key 다운로드

```bash
# Service Account 생성
gcloud iam service-accounts create terraform \
  --display-name="Terraform Service Account"

# Service Account에 권한 부여
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:terraform@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/editor"

# Key 다운로드
gcloud iam service-accounts keys create ~/gcp-terraform-key.json \
  --iam-account=terraform@YOUR_PROJECT_ID.iam.gserviceaccount.com
```

### 3. 환경 변수 설정

```bash
# .env.example을 복사하여 .env 생성
cp .env.example .env

# .env 파일 편집 (실제 값으로 수정)
# - GOOGLE_APPLICATION_CREDENTIALS
# - GOOGLE_PROJECT
# - TF_VAR_project_id
# - TF_VAR_postgres_password

# 환경 변수 로드
source .env
```

### 4. Terraform Variables 설정

```bash
# terraform.tfvars.example을 복사하여 terraform.tfvars 생성
cp terraform.tfvars.example terraform.tfvars

# terraform.tfvars 파일 편집 (실제 값으로 수정)
```

## Deployment

### 1. Terraform 초기화

```bash
terraform init
```

### 2. 배포 계획 확인

```bash
terraform plan -var-file=terraform.tfvars
```

### 3. 인프라 배포

```bash
terraform apply -var-file=terraform.tfvars -auto-approve
```

배포 완료 후 출력되는 정보:
- `master_external_ip`: Master node external IP
- `cluster_endpoint`: Kubernetes API endpoint
- `argocd_url`: ArgoCD UI URL
- `grafana_url`: Grafana Dashboard URL
- `kiali_url`: Kiali Dashboard URL

## Bootstrap Process

Terraform apply 완료 후, master node에서 자동으로 다음 작업이 진행됩니다:

1. k3s server 설치 (~2-3분)
2. ArgoCD 설치 (~3-5분)
3. ArgoCD Applications 생성 및 동기화 (~2-3분)
4. PostgreSQL secret 생성

전체 bootstrap 과정: 약 10분 소요

## Monitoring Bootstrap Progress

```bash
# SSH로 master node 접속
gcloud compute ssh ubuntu@titanium-k3s-master --zone=asia-northeast3-a

# Bootstrap log 확인
tail -f /var/log/k3s-bootstrap.log
```

## Accessing Services

### 1. Kubernetes API

```bash
# Kubeconfig 다운로드
gcloud compute ssh ubuntu@titanium-k3s-master --zone=asia-northeast3-a \
  --command="sudo cat /etc/rancher/k3s/k3s.yaml" | \
  sed "s/127.0.0.1/$(terraform output -raw master_external_ip)/g" > ~/.kube/config-gcp

# Kubeconfig 사용
export KUBECONFIG=~/.kube/config-gcp

# Cluster 확인
kubectl get nodes
kubectl get pods --all-namespaces
```

### 2. ArgoCD

```bash
# ArgoCD UI 접속
# URL: http://<master_external_ip>:30080

# Admin password 확인
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

### 3. Grafana Dashboard

```bash
# URL: http://<master_external_ip>:31300
```

### 4. Kiali Dashboard

```bash
# URL: http://<master_external_ip>:31200
```

## GitOps Applications

ArgoCD를 통해 자동으로 배포되는 applications:

1. **titanium-prod**: Main application stack
   - Source: https://github.com/DvwN-Lee/Monitoring-v2.git
   - Path: k8s-manifests/overlays/solid-cloud
   - Auto-sync: enabled

2. **loki-stack**: Logging and monitoring
   - Source: Grafana Helm Charts
   - Chart: loki-stack 2.10.2
   - Auto-sync: enabled

## Cleanup

```bash
# 모든 리소스 삭제
terraform destroy -var-file=terraform.tfvars -auto-approve
```

## Cost Estimation

예상 월 비용 (asia-northeast3):
- Master (e2-medium): ~$25/month
- Workers (e2-medium x 2): ~$50/month
- Network egress: 변동 (Free tier: 1GB/month)
- Disk (standard PD): ~$5/month

총 예상 비용: ~$80-100/month

## Troubleshooting

### Bootstrap 실패 시

```bash
# Bootstrap log 확인
gcloud compute ssh ubuntu@titanium-k3s-master --zone=asia-northeast3-a \
  --command="tail -100 /var/log/k3s-bootstrap.log"

# k3s status 확인
gcloud compute ssh ubuntu@titanium-k3s-master --zone=asia-northeast3-a \
  --command="sudo systemctl status k3s"
```

### Firewall 문제

```bash
# Firewall rules 확인
gcloud compute firewall-rules list

# 특정 rule 확인
gcloud compute firewall-rules describe titanium-k3s-allow-ssh
```

### Network 문제

```bash
# VPC network 확인
gcloud compute networks list

# Subnet 확인
gcloud compute networks subnets list
```

## Notes

- GCP는 egress traffic을 기본으로 허용하므로 CloudStack의 egress firewall 문제가 없습니다
- External IP는 static으로 할당되어 재시작 후에도 유지됩니다
- Startup script는 instance 첫 부팅 시 자동 실행됩니다
- SSH key는 GCP metadata를 통해 자동 추가됩니다
