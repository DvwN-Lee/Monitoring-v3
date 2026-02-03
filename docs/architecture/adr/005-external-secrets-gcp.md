# ADR-005: External Secrets Operator + GCP Secret Manager

**날짜**: 2026-01-20

---

## 상황 (Context)

Kubernetes Secret 관리에서 다음 문제가 발생했다:
- Git Repository에 Secret 값을 저장할 수 없음 (보안)
- ArgoCD GitOps 환경에서 Secret 동기화 방법 필요
- 개발/스테이징/프로덕션 환경별 Secret 분리 필요

Secret을 Git 외부에서 관리하면서도 GitOps 워크플로우를 유지해야 한다.

## 결정 (Decision)

External Secrets Operator(ESO)를 도입하고, GCP Secret Manager를 Backend로 사용한다.

구성:
- `ExternalSecret` CR: Secret 매핑 정의 (Git 저장)
- `SecretStore`: GCP Secret Manager 연결 설정
- GCP Workload Identity: Service Account 기반 인증

Secret 흐름:
```
GCP Secret Manager -> External Secrets Operator -> Kubernetes Secret -> Pod
```

## 이유 (Rationale)

| 항목 | External Secrets | Sealed Secrets | Vault |
|------|------------------|----------------|-------|
| Secret 저장소 | Cloud Provider (GCP, AWS) | Git (암호화) | Self-hosted |
| GitOps 호환 | ExternalSecret CR만 Git 저장 | 암호화된 Secret Git 저장 | 별도 연동 필요 |
| 운영 부담 | 낮음 (Managed Service 활용) | 낮음 | 높음 (Vault 운영) |
| 환경 분리 | Cloud Provider IAM | Namespace별 Key | Policy 기반 |
| 비용 | GCP Secret Manager 사용량 | 무료 | Self-hosted 비용 |

GCP를 이미 사용 중이므로 Secret Manager와 자연스럽게 통합된다. Sealed Secrets는 암호화 키 관리가 필요하고, Vault는 별도 운영 부담이 있다.

## 결과 (Consequences)

### 긍정적 측면
- Secret 값이 Git에 노출되지 않음
- GCP Console에서 Secret 중앙 관리
- ExternalSecret CR만 Git에 저장하여 GitOps 유지
- Secret 버전 관리 및 Rotation 지원

### 부정적 측면 (Trade-offs)
- GCP Secret Manager 의존성 발생
- ESO Pod 장애 시 Secret 동기화 중단
- Workload Identity 설정 복잡도
- Secret 동기화 지연 가능 (refreshInterval 설정)
