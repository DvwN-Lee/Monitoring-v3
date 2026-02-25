# Troubleshooting Index

K3s + ArgoCD + GitOps 기반 인프라 배포 및 테스트 중 발생한 문제와 해결 방법을 카테고리별로 분류한다.

## 카테고리별 문제 목록

### [Infrastructure](infrastructure/README.md) (3건)

VM, Network, Firewall 등 GCP Infrastructure 관련 문제.

| # | 문제 | 핵심 원인 |
|---|------|----------|
| 2 | Istio Gateway NodePort 불일치 | Helm values와 Terraform Firewall 포트 불일치 |
| 7 | ArgoCD PVC Health Check 실패 | `WaitForFirstConsumer` 상태를 비정상으로 판단 |
| 10 | Traffic Generator NetworkPolicy 차단 | Zero Trust 모델에서 허용 목록 누락 |

### [Istio](istio/README.md) (3건)

Service Mesh, Gateway, VirtualService 관련 문제.

| # | 문제 | 핵심 원인 |
|---|------|----------|
| 3 | VirtualService Health Check Rewrite 오류 | prefix rewrite가 URI 전체 대체 |
| 5 | Istio Gateway Sidecar Injection 실패 | Webhook 등록 전 Pod 생성 |
| 19 | Regional MIG maxSurge 오류 | maxSurge 값이 Zone 수보다 작음 |

### [Secrets](secrets/README.md) (3건)

Secret 관리, External Secrets Operator 관련 문제.

| # | 문제 | 핵심 원인 |
|---|------|----------|
| 1 | PostgreSQL Password Race Condition | ExternalSecret 타이밍 문제 |
| 6 | ExternalSecret Operator CRD/Webhook 오류 | CRD 미설치, cert-controller 비활성화 |
| 8 | Kustomize namePrefix Secret 참조 오류 | `$patch: delete`로 namePrefix 변환 누락 |

### [Monitoring](monitoring/README.md) (1건)

Prometheus, Grafana, Loki 관련 문제.

| # | 문제 | 핵심 원인 |
|---|------|----------|
| 4 | Grafana Datasource isDefault 충돌 | Loki와 Prometheus 모두 isDefault: true |

### [Application](application/README.md) (1건)

Microservice Application 관련 문제.

| # | 문제 | 핵심 원인 |
|---|------|----------|
| 9 | Redis Password 미설정 | 인증 없이 접근 가능한 보안 취약점 |

### [Testing](testing/README.md) (8건)

Terratest 및 테스트 자동화 관련 문제.

| # | 문제 | 핵심 원인 |
|---|------|----------|
| 11 | JSON 파싱 에러 | `diskSizeGb` 타입 불일치 (string vs int64) |
| 12 | SSH 키 경로 문제 | Terraform `file()` 함수 tilde 미지원 |
| 13 | Service Account 충돌 | 이전 테스트 리소스 미정리 |
| 14 | Firewall Source Ranges 테스트 실패 | `.auto.tfvars` 잔존 파일 |
| 15 | Network Layer 테스트 문제 | VPC 중복 생성 |
| 16 | 테스트 Timeout | 기본 30분 초과 |
| 17 | 리소스 정리 실패 | 테스트 실패 후 GCP 리소스 잔존 |
| 18 | k3s Node Password Rejection | MIG 재생성 시 hostname 충돌 |

## 참조

- 기존 통합 문서: [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) (전체 내용 포함)
- [Secret Management](../secret-management.md)
- [Operational Changes](../operational-changes.md)

## 일반 디버깅 팁

### 로그 확인

```bash
# Terraform 로그
export TF_LOG=DEBUG
terraform apply

# Pod 로그
kubectl logs -n <NAMESPACE> <POD_NAME> -f

# Event 확인
kubectl get events -n <NAMESPACE> --sort-by='.lastTimestamp'
```

### 특정 Terratest만 실행

```bash
go test -v -run "TestComputeAndK3s/MasterInstanceSpec" -timeout 10m
```
