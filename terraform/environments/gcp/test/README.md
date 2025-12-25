# Terratest for GCP K3s Monitoring Stack

GCP K3s infrastructure와 monitoring stack의 자동화된 테스트 프레임워크입니다.

## 테스트 아키텍처

Bottom-Up 레이어 접근 방식으로 빠른 피드백과 비용 효율성을 제공합니다.

| Layer | 테스트 | 비용 | 시간 | 목적 |
|-------|--------|------|------|------|
| 0 | Static Validation | $0 | <1분 | Format & Syntax 검증 |
| 1 | Plan Unit Tests | $0 | <3분 | Plan 분석, 리소스 구성 검증 |
| 2 | Network Layer | 낮음 | <5분 | VPC/Subnet/Firewall 검증 |
| 3 | Compute & K3s | 중간 | 5-6분 | VM, SSH, K3s, 멱등성 검증 |
| 4 | Full Integration | 높음 | 6분 | E2E, ArgoCD, Monitoring |

## 사전 요구사항

### 1. Go 설치
```bash
# macOS
brew install go

# 버전 확인
go version  # go1.21 이상 권장
```

### 2. GCP 인증
```bash
# GCP 인증
gcloud auth application-default login

# 프로젝트 설정
gcloud config set project titanium-k3s-1765951764
```

### 3. SSH 키 설정
```bash
# 테스트에서 사용하는 SSH 키 생성 (없는 경우)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/titanium-key -C "titanium-k3s-cluster"
```

### 4. 환경 변수
```bash
export GOOGLE_PROJECT="titanium-k3s-1765951764"
export GOOGLE_REGION="asia-northeast3"
export GOOGLE_ZONE="asia-northeast3-a"
```

## 빠른 시작

### 전체 테스트 실행 (권장)
```bash
cd test

# 의존성 설치
go mod download

# Layer 0-1: Static Validation & Plan Unit (비용 없음)
go test -v -run "TestTerraform|TestPlan" -timeout 10m

# Layer 3: Compute & K3s + 멱등성 (약 6분)
go test -v -run "TestComputeAndK3s|TestComputeIdempotency" -timeout 30m

# Layer 4: Full Integration (약 6분)
go test -v -run "TestFullIntegration" -timeout 45m
```

### 멱등성만 빠르게 검증
```bash
go test -v -run "TestComputeIdempotency" -timeout 30m
```

## 테스트 상세 설명

### Layer 0: Static Validation

비용 없이 빠르게 Terraform 코드 품질을 검증합니다.

**포함된 테스트:**
- `TestTerraformFormat`: 코드 포맷팅 검사 (`terraform fmt -check`)
- `TestTerraformValidate`: 구문 유효성 검사

```bash
go test -v -run "TestTerraform" -timeout 5m
```

**실행 시간**: <1분
**비용**: $0

---

### Layer 1: Plan Unit Tests

실제 리소스 생성 없이 Terraform Plan을 분석하여 구성을 검증합니다.

**포함된 테스트:**
- `TestPlanResourceCount`: 리소스 개수 검증 (14개)
- `TestPlanNetworkConfig`: VPC/Subnet CIDR 검증
- `TestPlanComputeConfig`: Master/Worker 사양 검증
- `TestPlanFirewallRules`: 필수 Firewall 규칙 검증
- `TestPlanOutputDefinitions`: 필수 Output 정의 검증
- `TestPlanNoSensitiveHardcoding`: 민감정보 하드코딩 방지
- `TestPlanInvalidInputs`: Negative 테스트 (잘못된 입력)
- `TestPlanFirewallSourceRanges`: SSH IAP 제한 검증
- `TestPlanFirewallNoWideOpen`: 0.0.0.0/0 개방 경고

```bash
go test -v -run "TestPlan" -timeout 5m
```

**실행 시간**: <3분
**비용**: $0

---

### Layer 2: Network Layer Tests

VPC, Subnet, Firewall 리소스를 실제 생성하여 검증합니다.

```bash
go test -v -run "TestNetwork" -timeout 15m
```

**실행 시간**: <5분
**비용**: 낮음 (~$0.1)

---

### Layer 3: Compute & K3s Tests

VM 생성, SSH 연결, K3s 클러스터 배포를 검증합니다.

**TestComputeAndK3s:**
- Master/Worker 인스턴스 사양 검증
- Spot 인스턴스 구성 확인
- SSH 연결성 테스트
- K3s 서비스 상태 확인
- K3s 노드 Ready 상태 검증
- 시스템 Pod (CoreDNS, Metrics Server) 검증
- IAM 권한 (Logging/Monitoring) 검증

**TestComputeIdempotency (멱등성 검증):**
- 첫 번째 `terraform apply` 실행
- 두 번째 `terraform plan` 실행
- Exit code 0 확인 (변경 사항 없음)
- 멱등성 보장 검증

```bash
# 전체 Compute Layer 테스트
go test -v -run "TestCompute" -timeout 30m

# 멱등성만 테스트
go test -v -run "TestComputeIdempotency" -timeout 30m
```

**실행 시간**: 5-6분
**비용**: 중간 (~$0.3-$0.5)

**멱등성 검증 결과 예시:**
```
TestComputeIdempotency 2025-12-24T22:33:47+09:00 logger.go:66:
Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.

멱등성 테스트 통과: 재적용 시 변경 사항 없음
--- PASS: TestComputeIdempotency (276.67s)
```

---

### Layer 4: Full Integration Tests

전체 스택 (Infrastructure + K3s + ArgoCD + Monitoring)을 E2E로 검증합니다.

**검증 항목:**
- Infrastructure Outputs (VPC, Subnet, IP 등)
- Kubeconfig Access
- Namespace Setup (argocd, monitoring, istio-system 등)
- ArgoCD Applications (7개 앱 배포 상태)
- Monitoring Stack (Prometheus, Grafana, Loki)
- Application Endpoints (HTTP 접근성)

```bash
go test -v -run "TestFullIntegration" -timeout 45m
```

**실행 시간**: 6분
**비용**: 높음 (~$0.5-$1)

---

## 병렬 테스트 실행

테스트는 기본적으로 격리된 환경에서 병렬 실행됩니다.

**격리 메커니즘:**
- `GetIsolatedTerraformOptions()`: 임시 디렉터리 + 랜덤 클러스터명
- 각 테스트가 독립적인 Terraform state 사용
- 리소스 이름 충돌 방지 (예: `tt-abc123-vpc`)

```bash
# 여러 테스트를 동시 실행
go test -v -run "TestCompute|TestPlan" -timeout 30m -parallel 4
```

---

## 테스트 결과 해석

### 성공 케이스
```
=== RUN   TestComputeIdempotency
TestComputeIdempotency 2025-12-24T22:33:47+09:00 logger.go:66:
Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.

    30_compute_k3s_test.go:151: 멱등성 테스트 통과: 재적용 시 변경 사항 없음
--- PASS: TestComputeIdempotency (276.67s)
PASS
ok      github.com/DvwN-Lee/Monitoring-v2/terraform/environments/gcp/test      321.946s
```

### 실패 케이스 예시
```
--- FAIL: TestComputeAndK3s/MasterInstanceSpec (1.00s)
    30_compute_k3s_test.go:190:
        Error: json: cannot unmarshal string into Go struct field .disks.diskSizeGb of type int64
        Test: TestComputeAndK3s/MasterInstanceSpec
        Messages: Instance JSON 파싱 실패
```

---

## Troubleshooting

자세한 문제 해결 가이드는 [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)를 참조하세요.

### 빠른 해결책

**테스트 실패 시:**
```bash
# 로그 확인
tail -100 /tmp/phase*-test.log

# 수동 cleanup
cd /Users/idongju/Desktop/Git/Monitoring-v3/terraform/environments/gcp
terraform destroy -auto-approve
```

**GCP 리소스 정리:**
```bash
# 남아있는 테스트 리소스 확인
gcloud compute instances list --filter="name~^tt-"
gcloud compute networks list --filter="name~^tt-"

# 수동 삭제
gcloud compute instances delete INSTANCE_NAME --zone=asia-northeast3-a --quiet
```

---

## CI/CD 통합

### GitHub Actions 예제

```yaml
name: Terratest

on:
  pull_request:
    paths:
      - 'terraform/environments/gcp/**'
  push:
    branches: [main]

jobs:
  static-validation:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.21'

      - name: Static Validation
        working-directory: terraform/environments/gcp/test
        run: |
          go mod download
          go test -v -run "TestTerraform|TestPlan" -timeout 10m

  idempotency-test:
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.21'

      - uses: google-github-actions/auth@v2
        with:
          credentials_json: ${{ secrets.GCP_SA_KEY }}

      - name: Idempotency Test
        working-directory: terraform/environments/gcp/test
        run: |
          go mod download
          go test -v -run "TestComputeIdempotency" -timeout 30m
```

---

## 비용 최적화

### 전략
1. **PR마다 Layer 0-1만 실행** (비용 없음)
2. **Main branch merge 시 Layer 3-4 실행**
3. **매일 1회 Full Integration 실행** (Scheduled)

### 예상 비용
- Layer 0-1: $0
- Layer 2: ~$0.1
- Layer 3: ~$0.3-$0.5
- Layer 4: ~$0.5-$1

**월간 예상 비용** (Main merge 시만 실행):
- 주 5회 merge × Layer 3-4 실행: ~$15-20/월

---

## 테스트 파일 구조

```
test/
├── 00_static_validation_test.go    # Layer 0
├── 10_plan_unit_test.go            # Layer 1
├── 20_network_layer_test.go        # Layer 2
├── 30_compute_k3s_test.go          # Layer 3 (멱등성 포함)
├── 40_full_integration_test.go     # Layer 4
├── helpers.go                       # 공통 헬퍼 함수
├── ssh_helpers.go                   # SSH 관련 헬퍼
├── go.mod
├── go.sum
├── README.md                        # 이 문서
└── TROUBLESHOOTING.md               # 문제 해결 가이드
```

---

## 참고 자료

- [Terratest 공식 문서](https://terratest.gruntwork.io/)
- [Terraform Testing Best Practices](https://developer.hashicorp.com/terraform/tutorials/configuration-language/test)
- [GCP Compute Engine API](https://cloud.google.com/compute/docs/reference/rest/v1)
- [K3s 공식 문서](https://docs.k3s.io/)
