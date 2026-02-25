# Changelog

[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 형식을 기반으로 작성한다.

## [1.0.0] - 2026-02-10

Production 환경 안정화 및 문서 정비 완료.

### Added

- 시스템 아키텍처 문서 및 Mermaid 다이어그램 (`docs/architecture/README.md`)
- Architecture Decision Records 10개 (ADR-001 ~ ADR-010)
- GCP Production 환경 Demo 문서 및 스크린샷 (`docs/demo/`)
- 프로젝트 README 전면 개편

### Changed

- 메인 아키텍처 다이어그램에 CI/CD 흐름 통합
- Troubleshooting 문서 통합 및 outdated 내용 정리
- 문서-코드 간 정합성 불일치 전면 수정

### Removed

- 미사용 `hashicorp/http` Provider lock
- 일회성 테스트 리포트 및 오래된 분석 문서
- 레거시 `argocd/` 폴더 및 불필요 파일

## [0.9.0] - 2026-02-04

Kiali Service Mesh Dashboard 안정화 및 Demo 검증 완료.

### Added

- GCP Production 환경 데모 문서 및 스크린샷 23종
- Namespace별 Istio Sidecar Injection 상태 설명

### Fixed

- Kiali multi-cluster 자동 감지 비활성화 (`clustering.autodetect_secrets.enabled: false`)
- Kiali Prometheus URL에 `/prometheus` 경로 추가
- Kiali `kubernetes_config.cluster_name` 및 `istio_api_enabled` 설정
- Traffic Generator 이메일 도메인을 `example.com`으로 변경

### Changed

- Terraform Hybrid IP 관리 방식으로 전환

## [0.8.0] - 2026-02-02

IaC 배포 안정화 및 Production 환경 최초 정상 동작 달성.

### Fixed

- PostgreSQL password race condition 해결 (Sync Wave 도입)
- Istio Gateway NodePort를 Terraform Firewall 설정과 일치 (`31080`, `31443`)
- Istio Gateway sidecar injection 자동 복구 로직
- Grafana `datasource isDefault` 충돌 해결
- ExternalSecret Operator CRD 설치 활성화
- ArgoCD PVC Health Check (`WaitForFirstConsumer` 대응)
- Kustomize `namePrefix` Secret 참조 오류
- Istio Gateway image repository 명시로 `ImagePullBackOff` 해결

### Changed

- Redis probe에서 password 노출 방지
- `upload_secret` Error Handling 개선

## [0.7.0] - 2026-02-01

External Secrets + GCP Secret Manager 연동 완료.

### Added

- ExternalSecret Operator `certController` 활성화로 webhook TLS cert 생성
- ExternalSecret CRD 설치 활성화

### Changed

- Secret 관리를 GCP Secret Manager 단일 소스로 통합
- ESO 인증을 SA Key JSON에서 GCE ADC 방식으로 전환

### Fixed

- Redis password 인증 설정 및 미사용 `postgresql-secret` 제거
- Grafana `root_url` 포트 설정
- Service Account에 `secretmanager.admin` Role 추가
- Istio `failurePolicy` diff `ignoreDifferences` 추가
- `RespectIgnoreDifferences` 추가로 Secret 덮어쓰기 방지

## [0.6.0] - 2026-01-31

Kubernetes Manifest 정적 분석 기반 수정 및 Monitoring 접근성 개선.

### Fixed

- IaC 정적 분석 기반 NetworkPolicy 및 ServiceMonitor 수정
- Grafana Init Container 권한 오류
- Prometheus VirtualService URI rewrite 제거
- Prometheus Probe timeout 증가로 readiness 안정성 개선

### Changed

- Kustomize `commonLabels`를 `labels`로 전환 (deprecation 대응)
- 동적 `.auto.tfvars` 파일 생성을 `Vars` map 직접 주입으로 전환
- ExternalSecret `secretStoreRef namePrefix` 불일치 수정
- PostgreSQL `PGDATA` 환경변수 추가 (GCE PD `lost+found` 대응)

## [0.5.0] - 2026-01-24

Istio Service Mesh 정책 공식화 및 Secret Management 구현.

### Added

- Istio mTLS (STRICT mode) 정책 공식화 및 전체 Namespace 검증 완료
- External Secrets + GCP Secret Manager 연동 (PR #89)
- Zero Trust NetworkPolicy 모델 구현
- Secret Management 운영 문서 (`docs/secret-management.md`)
- Operational Changes 이력 문서 (`docs/operational-changes.md`)

### Fixed

- VirtualService Health Check Rewrite 오류
- JWT Secret Key 누락 문제

## [0.4.0] - 2026-01-16

Monitoring Stack 자동화 배포 완료.

### Added

- ArgoCD 기반 Monitoring Stack 자동화 배포 (Prometheus, Loki, Grafana)
- ServiceMonitor 기반 Metrics 자동 수집

### Fixed

- Loki 이미지 버전을 `2.9.3`으로 업그레이드 (Logs Volume 오류 수정)
- Promtail Pipeline을 regex 기반으로 변경
- PostgreSQL StatefulSet/Service Label 일관성 수정
- ArgoCD Degraded 상태 대응 `Functionally Ready` 로직

## [0.3.0] - 2026-01-12

테스트 자동화 도입 및 안정화.

### Added

- 코드 레벨 단위 테스트 도입 (pytest, go test)
- Terratest Layer 2-5 구현 및 안정화

### Fixed

- MIG e2 인스턴스 scheduling 설정 및 타임아웃 문제
- Monitoring Stack 테스트 대기 시간 조정
- ArgoCD Application 이름 수정 (`monitoring-stack` -> `titanium-prod`)
- Worker 인스턴스 이름 패턴 동적 조회 및 State 격리

## [0.2.0] - 2026-01-05

보안 강화 및 HTTPS/TLS 구현.

### Added

- HTTPS/TLS 및 JWT RS256 자동 생성
- auth-service JWT RS256 키 Secret

### Fixed

- Backend Critical Security 취약점 수정
- Terraform Firewall CIDR validation 추가 및 `0.0.0.0/0` 차단
- CORS wildcard 설정을 특정 Domain 제한으로 변경
- API Gateway Security 강화 (Rate Limiting, Security Headers)

## [0.1.0] - 2025-12-31

GCP Infrastructure 자동화 기반 구축.

### Added

- GCP K3s Infrastructure Terraform 코드
- ArgoCD GitOps 초기 구조 (App of Apps 정식 전환은 v0.4.0)
- Terraform 변수화 및 Environment 분리 구조
- kubeconfig 자동화 및 ArgoCD 버전 고정
- Admin IP 자동 감지 기능
- GitHub Issue Template 및 ADR 문서

### Changed

- 하드코딩 제거 및 변수화 개선
- mTLS STRICT 환경(v0.0.1에서 적용)에 맞게 테스트 스크립트 수정

## [0.0.1] - 2025-12-18 ~ 12-29

프로젝트 초기 구성 및 기반 Infrastructure 구축.

### Added

- Monitoring-v2 기반 서비스 코드 및 인프라 구성 추가
- GCP K3s Infrastructure 및 GitOps 자동화 프로젝트 초기 구성
- CloudStack에서 GCP 환경으로 설정 전환
- Terratest Bottom-Up 구조 설계
- MIG 기반 Worker Node Auto-healing (12-29)
- PostgreSQL 배포 및 Istio Sidecar Injection 설정
- Istio mTLS STRICT mode 초기 적용 (12-29)
- Infrastructure 보안 강화 및 Monitoring 테스트 자동화
