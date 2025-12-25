# Terratest Development Log

GCP K3s Monitoring Stack Terratest 개발 과정과 주요 의사결정을 기록한 문서입니다.

## 프로젝트 개요

**목표**: GCP K3s infrastructure의 신뢰성 높은 자동화 테스트 프레임워크 구축

**주요 요구사항**:
- Terraform 코드의 정확성 검증
- 멱등성 보장 확인
- 비용 효율적인 테스트 전략
- CI/CD 통합 가능한 구조

---

## 개발 히스토리

### Phase 1: 테스트 아키텍처 설계 (2025-12-23)

**의사결정: Bottom-Up Layer 접근 방식 채택**

기존 통합 테스트만 있던 구조를 계층화하여 재구성했습니다.

**변경 전**:
```
test/
└── integration_test.go  # 단일 통합 테스트 (20분+, 높은 비용)
```

**변경 후**:
```
test/
├── 00_static_validation_test.go    # Layer 0: 무비용, <1분
├── 10_plan_unit_test.go            # Layer 1: 무비용, <3분
├── 20_network_layer_test.go        # Layer 2: 낮은 비용, <5분
├── 30_compute_k3s_test.go          # Layer 3: 중간 비용, 5-6분
└── 40_full_integration_test.go     # Layer 4: 높은 비용, 6분
```

**이점**:
- 빠른 피드백 루프 (Layer 0-1은 초 단위)
- 비용 최적화 (PR마다 무비용 테스트만 실행)
- 문제 격리 용이

---

### Phase 2: Plan Unit Tests 구현 (2025-12-23)

**구현 내용**: Terraform Plan JSON 분석 기반 테스트

```go
func TestPlanResourceCount(t *testing.T) {
    plan := terraform.InitAndPlan(t, terraformOptions)
    planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

    resourceCount := len(planStruct.ResourcePlannedValuesMap)
    assert.Equal(t, 14, resourceCount, "Expected 14 resources")
}
```

**검증 항목**:
- 리소스 개수 (14개)
- VPC CIDR 범위
- Compute Instance 사양
- Firewall 규칙 (필수 포트)
- Output 정의
- 민감정보 하드코딩 방지

**도전 과제**:
- Terraform Plan JSON 구조 파악
- 복잡한 nested 구조 탐색
- Firewall source_ranges 동적 검증

---

### Phase 3: Compute Layer & 멱등성 테스트 (2025-12-23)

**문제 1: SSH 키 경로 확장**

Terraform `file()` 함수가 tilde (`~`) 확장을 지원하지 않는 문제 발견

```hcl
# 해결책: pathexpand() 래핑
metadata = {
  ssh-keys = "ubuntu:${file(pathexpand(var.ssh_public_key_path))}"
}
```

**문제 2: 테스트 변수 누락**

`GetTestTerraformVars()`에 `ssh_public_key_path` 누락으로 기본값 사용

```go
// 해결책
"ssh_public_key_path": filepath.Join(homeDir, ".ssh", "titanium-key.pub"),
```

**멱등성 테스트 구현**:

```go
func TestComputeIdempotency(t *testing.T) {
    terraform.InitAndApply(t, terraformOptions)

    // 두 번째 Plan 실행 후 Exit code 확인
    exitCode := terraform.PlanExitCode(t, terraformOptions)

    if exitCode == 0 {
        t.Log("멱등성 테스트 통과: 재적용 시 변경 사항 없음")
    } else if exitCode == 2 {
        // 변경 사항 상세 출력
        planStruct := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)
        for _, change := range planStruct.RawPlan.ResourceChanges {
            t.Errorf("멱등성 실패: 리소스 '%s'에 변경 발생", change.Address)
        }
    }
}
```

**결과**: Exit code 0 확인, 멱등성 보장

---

### Phase 4: Full Integration 테스트 (2025-12-23)

**문제: Service Account 충돌**

```
Error 409: Service account terratest-k3s-sa already exists
```

**원인**: `GetDefaultTerraformOptions()` 사용으로 고정된 이름 사용

**해결책**:
```bash
gcloud iam service-accounts delete \
  terratest-k3s-sa@titanium-k3s-1765951764.iam.gserviceaccount.com \
  --quiet
```

**검증 항목**:
- Infrastructure Outputs
- Kubeconfig Access
- Namespace Setup
- ArgoCD Applications (7개)
- Monitoring Stack Pods
- Application Endpoints

---

### Phase 5: JSON 파싱 에러 해결 (2025-12-24)

**문제**: gcloud 응답의 diskSizeGb 타입 불일치

```
Error: json: cannot unmarshal string into Go struct field .disks.diskSizeGb of type int64
```

**근본 원인**:
- gcloud는 `diskSizeGb`를 **문자열**로 반환
- Go 구조체에서 `int64`로 정의

**해결책**:
```go
type GCPInstance struct {
    Disks []struct {
        Boot       bool   `json:"boot"`
        DiskSizeGb string `json:"diskSizeGb"`  // string으로 변경
    } `json:"disks"`
}

// 사용 시 파싱
var diskSize int64
fmt.Sscanf(disk.DiskSizeGb, "%d", &diskSize)
```

---

### Phase 6: Network Layer 테스트 수정 (2025-12-24)

**문제**: Firewall 이름 구성 로직 오류

```go
// Before
firewallName := fmt.Sprintf("%s-%s", vpcName, ruleSuffix)  // vpcName = "tt-xxx-vpc"

// After
clusterName := strings.TrimSuffix(vpcName, "-vpc")
firewallName := fmt.Sprintf("%s-%s", clusterName, ruleSuffix)  // clusterName = "tt-xxx"
```

**Output 추가**:
```hcl
output "vpc_name" {
  value = google_compute_network.vpc.name
}

output "subnet_name" {
  value = google_compute_subnetwork.subnet.name
}
```

---

## 최종 테스트 결과 (2025-12-24)

### 전체 실행 결과

| Phase | 테스트 | 결과 | 시간 |
|-------|--------|------|------|
| Phase 1 | Static Validation & Plan Unit | PASS | 5.6초 |
| Phase 2 | Compute & K3s | PASS | 320.97초 |
| Phase 2 | 멱등성 (Idempotency) | PASS | 276.67초 |
| Phase 3 | Full Integration | PASS | 348.87초 |

### 멱등성 검증 결과

```
Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.

멱등성 테스트 통과: 재적용 시 변경 사항 없음
--- PASS: TestComputeIdempotency (276.67s)
```

**Exit code 0 확인** → 멱등성 보장

---

## 기술 스택

### 테스트 프레임워크
- **Terratest** v0.46.8
- **testify** (assert, require)
- Go 1.21+

### 도구
- Terraform 1.5.7
- gcloud CLI
- kubectl

### GCP 리소스
- Compute Engine
- VPC Network
- Cloud IAM
- Service Accounts

---

## 주요 의사결정 기록

### 1. GetIsolatedTerraformOptions vs GetDefaultTerraformOptions

**의사결정**: Layer 3 (Compute)는 격리, Layer 4 (Full Integration)는 공유

**이유**:
- **Layer 3 (격리)**:
  - 병렬 실행 안전성
  - 멱등성 테스트 독립성
  - 랜덤 클러스터명으로 충돌 방지

- **Layer 4 (공유)**:
  - 실제 배포 환경 시뮬레이션
  - 고정 이름으로 디버깅 용이
  - Service Account 재사용

### 2. Timeout 설정

| 테스트 | Timeout | 이유 |
|--------|---------|------|
| Static/Plan | 10분 | 충분한 여유 |
| Compute | 30분 | K3s 부팅 시간 고려 |
| Full Integration | 45분 | ArgoCD Sync 대기 |

### 3. 비용 최적화 전략

**CI/CD 파이프라인 설계**:
```
PR 생성 → Layer 0-1 (무비용)
  ↓ (통과)
Main Merge → Layer 3-4 (유비용)
  ↓ (통과)
Daily Schedule → Full Integration (E2E 검증)
```

**예상 월간 비용**: ~$15-20

---

## 개선 사항

### 완료
- ✓ Layer 구조로 재설계
- ✓ 멱등성 테스트 추가
- ✓ JSON 파싱 에러 해결
- ✓ SSH 키 경로 문제 해결
- ✓ Service Account 충돌 해결
- ✓ Firewall 이름 로직 수정
- ✓ 문서화 (README, TROUBLESHOOTING)

### 향후 계획
- [ ] Network Layer 테스트 완전 수정
- [ ] E2E HTTP 테스트 추가
- [ ] ArgoCD Application Sync 상태 검증 강화
- [ ] Prometheus 타겟 스크래핑 검증
- [ ] 테스트 리포트 자동 생성
- [ ] GitHub Actions Workflow 추가

---

## 성능 메트릭

### 테스트 실행 시간 추이

| 버전 | 전체 시간 | 개선율 |
|------|----------|--------|
| v1.0 (통합 테스트만) | ~30분 | - |
| v2.0 (Layer 구조) | ~10분 (병렬) | 67% 개선 |

### 비용 절감

| 항목 | Before | After | 절감율 |
|------|--------|-------|--------|
| PR당 비용 | ~$1 | $0 | 100% |
| Merge당 비용 | ~$1 | ~$0.8 | 20% |

---

## 레슨 런

### 1. Terraform 함수 제약 이해
- `file()` 함수는 tilde 확장 미지원
- `pathexpand()` 사용 필요

### 2. GCP API 응답 타입 확인
- gcloud JSON 응답의 숫자 필드가 문자열일 수 있음
- 타입 안전성 고려 필요

### 3. 테스트 격리의 중요성
- 병렬 테스트 시 리소스 이름 충돌 주의
- `GetIsolatedTerraformOptions()` 적극 활용

### 4. 멱등성 검증 필수
- IaC의 핵심 원칙
- `terraform.PlanExitCode()` 활용

---

## 참고 문서

- [README.md](./README.md): 사용자 가이드
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md): 문제 해결 가이드
- [Terratest 공식 문서](https://terratest.gruntwork.io/)
- [GCP Best Practices](https://cloud.google.com/architecture/framework)
