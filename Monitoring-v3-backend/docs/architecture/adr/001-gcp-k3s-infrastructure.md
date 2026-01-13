# ADR-001: GCP + K3s 기반 Infrastructure 선택

**날짜**: 2025-12-31

---

## 상황 (Context)

Monitoring-v2 프로젝트는 Solid Cloud의 Managed Kubernetes를 사용했다. v3에서는 Infrastructure 자동화를 강화하고, Cloud Provider 수준의 리소스 관리까지 확장하려 한다. 이를 위해 IaaS 수준의 제어가 가능한 환경이 필요하다.

## 결정 (Decision)

Google Cloud Platform(GCP)의 Compute Engine 위에 K3s Cluster를 직접 구성한다. Terraform으로 전체 Infrastructure를 코드화하고, Bootstrap Script를 통해 K3s 및 기본 Stack(ArgoCD, Istio 등)을 자동 설치한다.

## 이유 (Rationale)

| 항목 | Managed K8s (Solid Cloud) | Self-managed K3s (GCP) |
|------|---------------------------|------------------------|
| IaC 범위 | Namespace 이하 | VM, Network, Firewall 전체 |
| 비용 | 고정 비용 | 사용량 기반 (Free Tier 활용 가능) |
| 학습 범위 | Kubernetes 운영 | Cloud Networking, VM 관리 포함 |
| Bootstrap 자동화 | 제한적 | 완전 자동화 가능 |

프로젝트 목표가 "End-to-End Infrastructure 자동화"이므로, VM 생성부터 Application 배포까지 단일 `terraform apply`로 완료되는 구조가 적합하다.

K3s는 단일 Binary로 구성되어 Bootstrap이 빠르고, Rancher 생태계와의 호환성이 좋다. Production 환경에서도 Edge Computing, IoT 시나리오에서 검증되었다.

## 결과 (Consequences)

### 긍정적 측면
- Terraform으로 Infrastructure 전체(VPC, Subnet, Firewall, VM, DNS)를 관리 가능
- Bootstrap Script를 통한 K3s + ArgoCD + Istio 완전 자동화 달성
- GCP Free Tier 활용으로 비용 최소화

### 부정적 측면 (Trade-offs)
- K3s Control Plane HA 구성이 Managed K8s 대비 복잡 (현재 Single Master)
- Cloud Provider 장애 시 직접 대응 필요
- etcd 백업/복구 등 운영 부담 증가
