# Documentation Index

Monitoring-v3 프로젝트의 전체 문서 구조를 안내한다.

## 읽기 순서

프로젝트를 처음 접하는 경우 아래 순서를 권장한다.

1. [Getting Started](00-getting-started/README.md) - 프로젝트 배경 및 첫 배포 가이드
2. [Architecture](architecture/README.md) - 시스템 아키텍처 상세
3. [ADR](architecture/adr/README.md) - 주요 아키텍처 의사결정 기록
4. [Implementation Summary](02-implementation/implementation-summary.md) - Phase별 구현 내역
5. [Operations Guide](03-operations/guides/operations-guide.md) - 일상 운영 가이드
6. [Troubleshooting](04-troubleshooting/README.md) - 문제 해결 가이드
7. [Performance](05-performance/README.md) - 성능 테스트 및 분석
8. [Demo](06-demo/demo-scenario.md) - 구조화된 Demo 시나리오

## 역할별 Navigation

### 개발자

| 문서 | 설명 |
|------|------|
| [Getting Started](00-getting-started/README.md) | 프로젝트 배경 및 환경 구축 |
| [Architecture](architecture/README.md) | 시스템 구조 이해 |
| [Implementation Summary](02-implementation/implementation-summary.md) | 구현 상세 및 기술 스택 |
| [Troubleshooting](04-troubleshooting/README.md) | 개발/배포 중 문제 해결 |
| [Performance](05-performance/README.md) | 부하 테스트 시나리오 및 결과 |

### 운영자

| 문서 | 설명 |
|------|------|
| [Operations Guide](03-operations/guides/operations-guide.md) | 배포 확인, 로그 조회, Scale 조정 |
| [Secret Management](secret-management.md) | Secret Rotation 및 관리 절차 |
| [Operational Changes](operational-changes.md) | 운영 변경 이력 |
| [Troubleshooting](04-troubleshooting/README.md) | 카테고리별 문제 해결 |

### 의사결정자

| 문서 | 설명 |
|------|------|
| [Requirements](01-planning/requirements.md) | MoSCoW 요구사항 및 달성률 |
| [Project Plan](01-planning/project-plan.md) | Timeline, Risk Matrix |
| [ADR](architecture/adr/README.md) | 아키텍처 의사결정 근거 |
| [Retrospective](07-retrospective/project-retrospective.md) | 프로젝트 회고 및 교훈 |

## 문서 구조

```
docs/
├── README.md                           # 현재 문서 (Navigation Hub)
├── 00-getting-started/
│   └── README.md                       # 프로젝트 배경 및 첫 배포 가이드
├── 01-planning/
│   ├── requirements.md                 # MoSCoW 요구사항
│   └── project-plan.md                 # Timeline 및 Risk 관리
├── 02-implementation/
│   └── implementation-summary.md       # Phase별 구현 상세
├── 03-operations/
│   └── guides/
│       └── operations-guide.md         # 일상 운영 가이드
├── 04-troubleshooting/
│   ├── README.md                       # Troubleshooting Index
│   ├── application/                    # Application 관련 문제
│   ├── infrastructure/                 # Infrastructure 관련 문제
│   ├── istio/                          # Istio/Service Mesh 문제
│   ├── monitoring/                     # Monitoring Stack 문제
│   ├── argocd/                         # ArgoCD/GitOps 문제
│   ├── secrets/                        # Secret 관리 문제
│   ├── networking/                     # Network/Firewall 문제
│   └── testing/                        # Terratest 관련 문제
├── 05-performance/
│   ├── README.md                       # 성능 요구사항 및 목표
│   ├── load-test-results.md            # k6 부하 테스트 결과
│   └── resource-usage-analysis.md      # 리소스 사용량 분석
├── 06-demo/
│   └── demo-scenario.md                # 구조화된 Demo Script
├── 07-retrospective/
│   └── project-retrospective.md        # 프로젝트 회고
├── architecture/
│   ├── README.md                       # 시스템 아키텍처 상세
│   └── adr/                            # Architecture Decision Records
├── demo/
│   └── README.md                       # Demo 스크린샷 및 검증 결과
├── TROUBLESHOOTING.md                  # 04-troubleshooting/로 이관 (리다이렉트)
├── secret-management.md                # Secret 관리 가이드
└── operational-changes.md              # 운영 변경 이력
```

## 관련 프로젝트 문서

| 문서 | 위치 | 설명 |
|------|------|------|
| [Project README](../README.md) | 루트 | 프로젝트 개요 및 Quick Start |
| [Terraform README](../terraform/environments/gcp/README.md) | terraform/ | IaC 상세 및 변수 설명 |
| [Terratest README](../terraform/environments/gcp/test/README.md) | terraform/test/ | 테스트 아키텍처 및 실행 방법 |
| [CHANGELOG](../CHANGELOG.md) | 루트 | 버전별 변경 이력 |
