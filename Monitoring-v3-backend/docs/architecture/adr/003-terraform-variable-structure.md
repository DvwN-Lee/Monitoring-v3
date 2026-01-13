# ADR-003: Terraform 변수화 및 Environment 분리 구조

**날짜**: 2025-12-31

---

## 상황 (Context)

Terraform 코드에서 IP 주소, Password, SSH Key Path 등이 하드코딩되어 있었다. 이로 인해:
- 다른 환경(개발/스테이징/프로덕션)에 배포하려면 코드 수정 필요
- 민감 정보가 Git History에 노출될 위험
- 코드 재사용성 저하

## 결정 (Decision)

모든 환경 의존적 값을 `variables.tf`로 추출하고, `terraform.tfvars` 또는 환경 변수(`TF_VAR_*`)로 주입한다. 민감 정보는 환경 변수로만 전달하며 `.tfvars` 파일에 포함하지 않는다.

디렉토리 구조:
```
terraform/
  environments/
    gcp/
      main.tf
      variables.tf
      outputs.tf
      terraform.tfvars.example   # 민감정보 제외 예시
      scripts/
        k3s-server.sh
        get-kubeconfig.sh
      Makefile
```

## 이유 (Rationale)

| 항목 | 하드코딩 | 변수화 |
|------|---------|--------|
| 환경 전환 | 코드 수정 필요 | tfvars 교체 또는 환경 변수 |
| 보안 | Git에 민감정보 노출 | 환경 변수로 분리 |
| 재사용성 | 낮음 | 높음 |
| CI/CD 통합 | 어려움 | GitHub Secrets 연동 용이 |

`templatefile()` 함수를 활용하여 Bootstrap Script 내의 변수도 Terraform에서 주입한다. 이를 통해 Script 내 하드코딩을 완전히 제거했다.

Admin IP 자동 감지(`curl -s ifconfig.me`)를 통해 개발자 환경에 따라 Firewall Rule이 자동 설정된다.

## 결과 (Consequences)

### 긍정적 측면
- 단일 코드베이스로 여러 환경 배포 가능
- 민감 정보가 Git에 노출되지 않음
- `make apply` 명령으로 환경 변수 검증 자동화
- `terraform.tfvars.example` 파일로 필요한 변수 문서화

### 부정적 측면 (Trade-offs)
- 배포 전 환경 변수 설정 필요 (초기 설정 복잡도 증가)
- 변수가 많아지면 관리 부담 증가
- `templatefile()` 사용 시 Script 디버깅이 다소 어려움
