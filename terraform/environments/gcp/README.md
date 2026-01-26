# GCP Environment - Complete GitOps Automation

Google Cloud Platform에서 k3s cluster와 ArgoCD를 완전 자동화로 배포하는 Terraform 설정입니다.

## Architecture

- **Provider**: Google Cloud Platform (GCP)
- **Infrastructure**: VPC, Subnet, Firewall, Compute Engine instances
- **Kubernetes**: k3s (1 master + 2 workers via MIG)
- **Worker Management**: Managed Instance Group (MIG) with Auto-healing
- **GitOps**: ArgoCD with App of Apps pattern
- **Automation**: Complete bootstrap via startup script

## Prerequisites

1. GCP Project 및 Billing 활성화
2. gcloud CLI 설치 및 인증
3. Terraform >= 1.5.0
4. SSH keypair 생성 (기본: ~/.ssh/id_rsa.pub)

## Quick Start

자동화 스크립트를 사용한 빠른 시작:

```bash
# 1. Init script로 자동 설정
./scripts/init-terraform.sh YOUR_PROJECT_ID

# 2. terraform.tfvars 파일 생성 및 수정
cp terraform.tfvars.example terraform.tfvars
# PROJECT_ID, SSH key path 등 수정

# 3. 배포
terraform plan -var-file="secrets.tfvars"
terraform apply -var-file="secrets.tfvars"
```

자세한 설정 방법은 [docs/terraform/setup-guide.md](../../../docs/terraform/setup-guide.md) 참조

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
- `worker_mig_name`: Worker MIG 이름
- `worker_instance_template`: Worker Instance Template 이름
- `worker_health_check`: Worker Health Check 이름

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
   - Path: k8s-manifests/overlays/gcp
   - Auto-sync: enabled

2. **loki-stack**: Logging and monitoring
   - Source: Grafana Helm Charts
   - Chart: loki-stack 2.10.2
   - Auto-sync: enabled

## Worker Node Auto-healing

Worker node는 Managed Instance Group(MIG)으로 관리되며, 자동 복구 기능을 제공합니다.

### 구성 요소

| Resource | 설명 |
|----------|------|
| `google_compute_health_check` | Kubelet port(10250) TCP Health Check |
| `google_compute_instance_template` | Worker VM 템플릿 (Spot VM 지원) |
| `google_compute_instance_group_manager` | Auto-healing policy, Rolling update |

### Health Check 설정

```hcl
check_interval_sec  = 10
timeout_sec         = 5
healthy_threshold   = 2
unhealthy_threshold = 3
```

### Auto-healing 동작

1. Health Check가 Worker의 Kubelet port(10250)를 모니터링
2. `unhealthy_threshold`(3회) 연속 실패 시 UNHEALTHY 상태 전환
3. MIG가 자동으로 해당 instance를 RECREATING
4. 새 instance가 생성되고 k3s에 자동 Join

### Rolling Update 정책

```hcl
update_policy {
  type                           = "PROACTIVE"
  max_surge_fixed                = 1
  max_unavailable_fixed          = 0
  replacement_method             = "SUBSTITUTE"
}
```

- `max_surge_fixed = 1`: 업데이트 시 1개 추가 instance 허용
- `max_unavailable_fixed = 0`: 업데이트 중 다운타임 없음

## MIG Management

### MIG 상태 확인

```bash
# MIG instance 목록
gcloud compute instance-groups managed list-instances titanium-k3s-worker-mig \
  --zone=asia-northeast3-a \
  --project=YOUR_PROJECT_ID
```

### Auto-healing 테스트

```bash
# Worker VM 강제 중지 (Auto-healing 트리거)
gcloud compute instances stop WORKER_INSTANCE_NAME \
  --zone=asia-northeast3-a \
  --project=YOUR_PROJECT_ID

# MIG 상태 모니터링
watch -n 5 'gcloud compute instance-groups managed list-instances titanium-k3s-worker-mig --zone=asia-northeast3-a --project=YOUR_PROJECT_ID'
```

### 수동 크기 조정

```bash
# Worker 수 변경
gcloud compute instance-groups managed resize titanium-k3s-worker-mig \
  --size=3 \
  --zone=asia-northeast3-a \
  --project=YOUR_PROJECT_ID
```

## Cleanup

```bash
# 모든 리소스 삭제
terraform destroy -var-file=terraform.tfvars -auto-approve
```

## Cost Estimation

예상 월 비용 (asia-northeast3):

| Resource | Standard VM | Spot VM |
|----------|-------------|---------|
| Master (e2-medium) | ~$25/month | N/A |
| Workers (e2-medium x 2) | ~$50/month | ~$15-20/month |
| Network egress | 변동 | 변동 |
| Disk (pd-balanced) | ~$10/month | ~$10/month |

총 예상 비용:
- Standard VM: ~$85-100/month
- Spot VM (Workers): ~$50-60/month

Spot VM 사용 시 `use_spot_for_workers = true` 설정

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
