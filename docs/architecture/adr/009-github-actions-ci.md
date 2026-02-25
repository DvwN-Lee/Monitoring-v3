# ADR-009: GitHub Actions CI Pipeline 선택

**날짜**: 2025-12-28

---

## 상황 (Context)

Application 코드 변경 시 자동으로 테스트, 빌드, 이미지 Push를 수행하는 CI Pipeline이 필요하다. CD는 ArgoCD가 담당하므로, CI는 이미지 빌드와 Manifest 업데이트까지만 수행한다.

## 결정 (Decision)

GitHub Actions를 CI Pipeline으로 사용한다. CI에서 테스트 + 빌드 + 이미지 Push를 수행하고, CD Pipeline에서 K8s Manifest의 Image Tag를 업데이트하여 ArgoCD가 감지하도록 한다.

## 이유 (Rationale)

| 항목 | Jenkins | GitHub Actions | GitLab CI |
|------|---------|---------------|-----------|
| 인프라 요구 | 별도 서버 필요 | GitHub 제공 (SaaS) | GitLab 서버 또는 SaaS |
| 설정 복잡도 | Jenkinsfile + Plugin 관리 | YAML Workflow | YAML Pipeline |
| GitHub 통합 | Webhook 별도 설정 | 네이티브 통합 | 별도 연동 |
| 비용 | 서버 유지 비용 | Public Repo 무료 | 제한적 무료 |
| 병렬 실행 | Agent 설정 필요 | Matrix Strategy 내장 | Stage 기반 |

프로젝트가 GitHub Repository에서 관리되므로, GitHub Actions의 네이티브 통합이 가장 효율적이다. 별도 CI 서버를 운영할 필요가 없으며, Public Repository에서 무제한 무료로 사용 가능하다.

### CI/CD 분리 구조

```
GitHub Actions (CI)          ArgoCD (CD)
├── Unit Test                ├── Git Repository Watch
├── Docker Build + Push      ├── Manifest 변경 감지
└── Manifest Image Tag 수정  └── K8s Cluster Sync
```

CI와 CD를 분리함으로써, CI 도구 변경 시 ArgoCD 기반 CD에 영향이 없다.

## 결과 (Consequences)

### 긍정적 측면
- 별도 CI 서버 불필요, GitHub SaaS 활용
- `paths-filter`를 통한 변경 감지: 수정된 Service만 선택적 빌드
- Matrix Strategy로 다중 Service 병렬 테스트
- ArgoCD와의 GitOps 흐름이 자연스럽게 연결

### 부정적 측면 (Trade-offs)
- GitHub에 대한 의존도 증가 (Vendor Lock-in)
- Self-hosted Runner 미사용 시 빌드 시간 제한 (6시간)
- Secret 관리를 GitHub Secrets에 별도로 설정해야 함
