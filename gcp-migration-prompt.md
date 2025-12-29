# Monitoring-v3 GCP 환경 설정 조정 작업

## 배경

Monitoring-v2 프로젝트의 모든 서비스 코드와 인프라 구성을 Monitoring-v3 repository로 마이그레이션 완료했습니다. 현재 코드는 CloudStack 기반 환경(solid-cloud)에 최적화되어 있으며, 이를 GCP(Google Cloud Platform) 환경에 맞게 조정해야 합니다.

**Repository**: https://github.com/DvwN-Lee/Monitoring-v3.git
**Current Branch**: main
**Last Commit**: e8fc60d (feat: Monitoring-v2 기반 서비스 코드 및 인프라 구성 추가)

## 프로젝트 구조

```
Monitoring-v3/
├── api-gateway/                  # Go reverse proxy
├── auth-service/                 # Python FastAPI 인증 서비스
├── blog-service/                 # Python FastAPI 블로그 서비스
├── user-service/                 # Python FastAPI 사용자 서비스
├── k8s-manifests/
│   ├── base/                     # Base Kubernetes manifests
│   ├── monitoring/               # Prometheus, Grafana, Loki, Kiali 설정
│   └── overlays/
│       ├── local/                # Minikube 환경
│       └── solid-cloud/          # CloudStack 환경 (→ GCP로 변경 필요)
├── argocd/
│   └── applications/
│       └── titanium-app.yaml     # ArgoCD Application 정의 (→ GCP용 수정 필요)
├── .github/workflows/
│   ├── ci.yml                    # CI pipeline
│   └── cd.yml                    # CD pipeline (→ GCP 배포 설정 필요)
├── terraform/                    # GCP 인프라 코드 (이미 존재)
├── scripts/                      # 배포/검증 scripts
├── tests/                        # E2E, integration, performance 테스트
├── docker-compose.yml            # Local 개발 환경
├── skaffold.yaml                 # Kubernetes local 개발
└── .env.k8s.example              # 환경 변수 template

```

## 목표

CloudStack(solid-cloud) 기반 설정을 GCP 환경에 맞게 조정하여, GCP Kubernetes cluster에 배포 가능한 상태로 만들기

## 작업 범위

### 1. Kubernetes Manifests 조정

**작업 위치**: `k8s-manifests/overlays/`

**필요 작업**:
- `overlays/solid-cloud/` 디렉터리를 `overlays/gcp/`로 복사 또는 이름 변경
- GCP 환경에 맞게 다음 파일들 수정:
  - `kustomization.yaml`: namespace, image registry 등 조정
  - `configmap-patch.yaml`: GCP 관련 환경 변수 업데이트
  - `secret-patch.yaml.example`: GCP secrets 구조에 맞게 조정
  - `patches/*.yaml`: GCP Kubernetes 특성에 맞는 resource 설정
  - `istio/*.yaml`: GCP LoadBalancer, Ingress 설정으로 변경
  - `hpa.yaml`: GCP monitoring metrics 사용하도록 조정

**주의사항**:
- CloudStack 특정 설정 (예: IP 주소 10.0.1.x) 제거
- GCP LoadBalancer type Service로 변경
- GCP persistent volume 설정 적용 (필요시)

### 2. ArgoCD Application 정의 수정

**작업 위치**: `argocd/applications/titanium-app.yaml`

**필요 작업**:
- `spec.source.targetRevision`: 적절한 branch/tag 설정
- `spec.source.path`: `k8s-manifests/overlays/gcp`로 변경
- `spec.destination.server`: GCP Kubernetes cluster 주소로 업데이트
- `spec.destination.namespace`: GCP namespace 설정

### 3. GitHub Actions Workflow 조정

**작업 위치**: `.github/workflows/cd.yml`

**필요 작업**:
- GCP authentication 설정 추가 (Workload Identity 또는 Service Account Key)
- GKE cluster credentials 가져오기 설정
- Docker image push를 GCP Artifact Registry 또는 Container Registry로 변경
- ArgoCD sync를 GCP cluster로 변경
- 환경 변수 및 secrets를 GitHub repository secrets에서 참조하도록 설정

**작업 위치**: `.github/workflows/ci.yml`

**필요 작업**:
- Docker image registry를 GCP로 변경 (필요시)
- 테스트 환경 설정 검토

### 4. 환경 변수 Template 업데이트

**작업 위치**: `.env.k8s.example`

**필요 작업**:
- CloudStack 관련 변수 제거
- GCP 관련 환경 변수 추가:
  - GCP project ID
  - GCP region/zone
  - GKE cluster name
  - GCP service endpoints
  - Artifact Registry URL

### 5. Scripts 조정

**작업 위치**: `scripts/`

**필요 작업**:
- `backup-solid-cloud.sh` → `backup-gcp.sh`로 변경 및 GCP 백업 로직 적용
- `restore-solid-cloud.sh` → `restore-gcp.sh`로 변경
- `verify-deployment.sh`: GCP cluster 검증 로직으로 수정
- 기타 scripts에서 CloudStack 특정 명령어/설정 제거

### 6. Monitoring 설정 검토

**작업 위치**: `k8s-manifests/monitoring/`

**필요 작업**:
- Prometheus, Grafana, Loki values 파일에서 GCP 특성 반영
- GCP managed monitoring service 통합 검토 (선택사항)
- ServiceMonitor 설정이 GCP 환경에서 동작하는지 확인

### 7. Documentation 업데이트

**필요 작업**:
- `README.md`: Monitoring-v3 프로젝트 개요 및 GCP 배포 가이드 작성
- `k8s-manifests/overlays/gcp/README.md`: GCP overlay 사용법 문서화
- 배포 절차, 필수 prerequisites (GCP project, GKE cluster, permissions 등) 명시

## 제약 사항

1. **기존 Terraform 코드 보존**: `terraform/` 디렉터리의 GCP 인프라 코드는 이미 존재하므로 수정하지 말 것
2. **Base Manifests 유지**: `k8s-manifests/base/` 디렉터리는 환경 중립적이므로 가능한 수정하지 말 것
3. **Service 코드 미변경**: `api-gateway/`, `auth-service/`, `blog-service/`, `user-service/`의 application 코드는 수정하지 말 것 (환경 변수로 동작하도록 이미 구성됨)
4. **Minikube Overlay 보존**: `k8s-manifests/overlays/local/`은 로컬 개발용이므로 유지

## 검증 기준

작업 완료 후 다음 사항들이 충족되어야 합니다:

1. `kubectl apply -k k8s-manifests/overlays/gcp` 명령이 오류 없이 실행됨
2. ArgoCD가 `argocd/applications/titanium-app.yaml`을 사용하여 GCP cluster에 sync 가능
3. GitHub Actions CD workflow가 GCP 환경에 배포 성공
4. 모든 service가 GCP LoadBalancer를 통해 외부 접근 가능
5. Monitoring stack (Prometheus, Grafana, Loki, Kiali)이 정상 동작

## 추가 참고 사항

- **기존 Monitoring-v2 구조 참고**: 필요시 `/Users/idongju/Desktop/Git/Monitoring-v2` 디렉터리 참조
- **GCP Terraform 상태**: Terraform state는 이미 관리되고 있으므로, 인프라가 이미 provisioned 되었다고 가정
- **Namespace 명명**: 기존 `titanium-prod`를 유지하거나 GCP 환경에 맞는 새 이름 사용 (일관성 유지)
- **문서 작성 언어**: 한국어 사용, 단 기술 용어는 영어 원문 사용 (예: Cluster, Pod, Service 등)

## 질문 사항

작업 중 다음 정보가 필요할 경우 사용자에게 확인:

1. GCP project ID 및 region/zone
2. GKE cluster name 및 endpoint
3. Artifact Registry 또는 Container Registry URL
4. GitHub Actions에서 사용할 GCP authentication 방식 (Workload Identity vs Service Account Key)
5. Domain name 및 Ingress 설정 (필요시)
6. 기존 solid-cloud overlay 디렉터리 삭제 또는 보존 여부

## 시작 지점

```bash
cd /Users/idongju/Desktop/Git/Monitoring-v3
git checkout -b feature/gcp-configuration
```

이 branch에서 작업을 진행하고, 완료 후 pull request를 생성하세요.
