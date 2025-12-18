# Monitoring v3 - GCP k3s Infrastructure

GCP 기반 k3s Kubernetes Cluster Infrastructure 및 GitOps 자동화 프로젝트

## 프로젝트 개요

Terraform을 사용하여 GCP에 k3s cluster를 배포하고, ArgoCD를 통한 GitOps 기반 application 배포를 자동화합니다.

## 주요 기능

### Infrastructure (Terraform)
- GCP Compute Engine 기반 k3s cluster 구성
- Master node + Worker node(s) 구성
- IAP (Identity-Aware Proxy) 기반 보안 SSH 접근
- Service Account 및 IAM 권한 관리
- VPC, Subnet, Firewall 자동 구성

### GitOps (ArgoCD)
- Helm chart 기반 ArgoCD 배포
- Application 자동 배포 및 관리
- Monitoring stack (Prometheus, Grafana, Loki)
- Service Mesh (Istio)

### 보안
- IAP tunneling을 통한 SSH 접근 (`35.235.240.0/20`)
- Shielded VM 구성 (Secure Boot, vTPM, Integrity Monitoring)
- Service Account 최소 권한 부여

## 디렉토리 구조

```
terraform/
├── environments/
│   └── gcp/              # GCP 환경 설정
│       ├── main.tf       # 메인 infrastructure 정의
│       ├── variables.tf  # 변수 정의
│       ├── outputs.tf    # 출력 값
│       ├── scripts/      # Startup scripts
│       └── test/         # Terratest 통합 테스트
└── modules/              # 재사용 가능한 Terraform 모듈
    ├── argocd/          # ArgoCD Helm 배포
    ├── argocd-apps/     # ArgoCD Applications
    ├── database/        # PostgreSQL
    ├── instance/        # Compute Instance
    ├── kubernetes/      # k8s 리소스
    ├── monitoring/      # Monitoring stack
    └── network/         # VPC, Subnet
```

## 사용 방법

### 사전 요구사항

- Terraform >= 1.5.0
- Google Cloud SDK (gcloud)
- kubectl
- Go >= 1.21 (테스트 실행 시)

### 배포

```bash
cd terraform/environments/gcp

# 변수 설정
export TF_VAR_project_id="your-gcp-project-id"
export TF_VAR_postgres_password="your-secure-password"

# Terraform 초기화
terraform init

# 배포 계획 확인
terraform plan

# 배포 실행
terraform apply
```

### SSH 접근 (IAP Tunneling)

```bash
# Master node 접근
gcloud compute ssh ubuntu@<cluster-name>-master \
  --zone=asia-northeast3-a \
  --tunnel-through-iap

# kubeconfig 가져오기
gcloud compute ssh ubuntu@<cluster-name>-master \
  --zone=asia-northeast3-a \
  --tunnel-through-iap \
  --command='sudo cat /etc/rancher/k3s/k3s.yaml'
```

### 테스트

```bash
cd terraform/environments/gcp/test

# 기본 검증 테스트
go test -v -run TestTerraformBasicValidation

# 통합 테스트 (실제 GCP 리소스 생성)
go test -v -run TestTerraformGCPDeployment -timeout 60m
```

## 테스트 구성

### Terratest 통합 테스트

5단계 검증:
1. Infrastructure outputs 검증
2. k3s Cluster 접근성 검증 (IAP tunneling)
3. ArgoCD Applications 검증
4. Monitoring Stack 검증
5. Grafana Datasource 검증

### 주요 테스트 기능

- IAP tunneling을 통한 실제 kubeconfig 획득
- k3s service 활성화 대기 (retry 로직)
- ArgoCD application 상태 확인
- Monitoring pod 상태 확인
- Grafana datasource 충돌 방지 검증

## 기술 스택

- **Infrastructure**: Terraform, GCP Compute Engine
- **Kubernetes**: k3s
- **GitOps**: ArgoCD
- **Monitoring**: Prometheus, Grafana, Loki
- **Service Mesh**: Istio
- **Testing**: Terratest, Go

## 보안 고려사항

- SSH는 IAP 범위로만 제한 (`35.235.240.0/20`)
- Shielded VM 활성화
- Service Account 최소 권한 원칙
- Firewall 규칙 세분화

## 참고 자료

- [Terraform GCP Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
- [k3s Documentation](https://docs.k3s.io/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [GCP IAP Documentation](https://cloud.google.com/iap/docs)

## License

MIT License
