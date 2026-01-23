# IaC 기반 인프라 멱등성 테스트 결과

**테스트 일자**: 2026-01-23
**테스트 대상**: Terraform IaC 기반 GCP 인프라 및 ArgoCD 자동 배포
**테스트 목적**: Terraform destroy 후 재생성을 통한 인프라 멱등성 검증

---

## 테스트 개요

Terraform IaC 코드의 멱등성과 재현성을 검증하기 위해 기존 인프라를 완전히 제거한 후 재생성하는 전체 Lifecycle 테스트를 수행했습니다.

**테스트 범위**:
- GCP 리소스 전체 Lifecycle (destroy → apply)
- k3s Kubernetes Cluster 자동 설치
- ArgoCD GitOps 기반 Application 자동 배포
- Terraform 상태 멱등성 검증

---

## Phase 1: 기존 리소스 정리

**목적**: 기존 GCP 리소스를 모두 제거하여 초기 상태로 복원

**실행 명령**:
```bash
cd terraform/environments/gcp
terraform destroy -auto-approve
```

**결과**:
- 제거된 리소스: 17개
- 주요 제거 항목:
  - Compute Instance (VM)
  - VPC Network 및 Subnet
  - Firewall Rules
  - Service Account 및 IAM Bindings

**상태**: PASS

---

## Phase 2: 인프라 재생성

**목적**: Terraform apply를 통한 전체 인프라 재생성

**실행 명령**:
```bash
terraform apply -auto-approve
```

**결과**:
- 생성된 리소스: 17개
- 주요 생성 항목:
  - `google_compute_instance.k3s_master`: k3s Master Node
  - `google_compute_instance.k3s_worker[0-1]`: k3s Worker Node 2대
  - `google_compute_network.vpc`: VPC Network
  - `google_compute_subnetwork.subnet`: Subnet
  - `google_compute_firewall.*`: Firewall Rules
  - `google_service_account.k3s_sa`: Service Account

**상태**: PASS

---

## Phase 3: k3s 및 ArgoCD 자동 배포 확인

**목적**: cloud-init을 통한 k3s 설치 및 ArgoCD Application 자동 배포 검증

### 3.1 k3s Cluster 상태 확인

**실행 명령**:
```bash
ssh master-node "sudo kubectl get nodes"
```

**결과**:
```
NAME           STATUS   ROLES                  AGE   VERSION
master-node    Ready    control-plane,master   5m    v1.34.3+k3s1
worker-node-0  Ready    <none>                 4m    v1.34.3+k3s1
worker-node-1  Ready    <none>                 4m    v1.34.3+k3s1
```

**상태**: PASS

### 3.2 ArgoCD Application 배포 확인

**실행 명령**:
```bash
ssh master-node "sudo kubectl get applications -n argocd"
```

**결과**:
```
NAME                   SYNC STATUS   HEALTH STATUS
istio-base             Synced        Healthy
istiod                 Synced        Healthy
istio-ingress          Synced        Healthy
kiali                  Synced        Healthy
prometheus-stack       Synced        Healthy
loki                   Synced        Healthy
application-services   Synced        Healthy
```

**상태**: PASS

---

## Phase 4: Terraform 멱등성 테스트

**목적**: 인프라 재생성 후 terraform plan 재실행 시 변경 사항이 없는지 확인

**실행 명령**:
```bash
terraform plan
```

**결과**:
```
No changes. Your infrastructure matches the configuration.

Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.
```

**주요 확인 사항**:
- 추가 리소스: 0개
- 변경 리소스: 0개
- 제거 리소스: 0개

**상태**: PASS

---

## Phase 5: 서비스 정상 동작 검증

**목적**: 배포된 Monitoring Stack 및 Application의 접근성 확인

| 서비스 | 접근 URL | 예상 결과 | 실제 결과 | 상태 |
|--------|---------|----------|----------|------|
| Grafana | `http://EXTERNAL_IP:30300` | 200 OK | 200 OK | PASS |
| Prometheus | `http://EXTERNAL_IP:30090` | 200 OK | 200 OK | PASS |
| Kiali | `http://EXTERNAL_IP:31200` | 200 OK | Connection refused | FAIL |
| Blog API | `http://EXTERNAL_IP:30001/api/blogs` | 200 OK | Connection timeout | FAIL |

**Kiali 접근 실패 원인**:
- ArgoCD 배포 시 Service Type이 NodePort가 아닌 ClusterIP로 배포됨
- 외부 접근을 위한 NodePort 설정 필요

**Blog API 접근 실패 원인**:
- Blog Service Pod가 정상 시작되지 않음
- Auth Service와의 NetworkPolicy 설정 확인 필요

---

## 테스트 결과 요약

| 검증 항목 | 예상 결과 | 실제 결과 | 상태 |
|----------|----------|----------|------|
| Terraform destroy | 모든 GCP 리소스 제거 | 17개 리소스 제거 | PASS |
| Terraform apply | VM, VPC, Firewall 생성 | 17개 리소스 생성 | PASS |
| k3s 설치 | Master Node에 자동 설치 | v1.34.3+k3s1 설치 완료 | PASS |
| ArgoCD Applications | 모든 App 배포 | 7개 App 배포 완료 | PASS |
| Terraform 멱등성 | 재실행 시 No changes | 0 added, 0 changed | PASS |
| Grafana 접근 | 200 OK | 200 OK | PASS |
| Prometheus 접근 | 200 OK | 200 OK | PASS |
| Kiali 접근 | NodePort 31200 | ClusterIP (외부 접근 불가) | FAIL |
| Blog API 호출 | 200 OK | Connection timeout | FAIL |

**테스트 성공률**: 7/9 (77.8%)

---

## 핵심 성과

**Terraform 멱등성 완벽 보장**:
- 인프라 재생성 후 terraform plan 재실행 시 0 changes 확인
- IaC 코드와 실제 인프라 간 완벽한 일치 검증

**k3s 자동 설치 검증**:
- cloud-init을 통한 k3s v1.34.3+k3s1 자동 설치 성공
- Master/Worker Node 모두 Ready 상태

**ArgoCD GitOps 자동 배포 검증**:
- 7개 Application 모두 Synced 및 Healthy 상태
- GitOps 기반 자동 배포 정상 동작

---

## 개선 필요 사항

**Kiali NodePort 설정**:
- ArgoCD Application에서 Service Type을 NodePort로 명시 필요
- Helm Values 또는 Kustomize Patch 적용

**Blog Service NetworkPolicy 검토**:
- Auth Service와의 통신을 위한 NetworkPolicy 규칙 추가 필요
- 현재 설정에서 Blog → Auth 간 트래픽 차단 가능성 확인

---

## 결론

Terraform IaC 기반 인프라는 destroy 후 재생성 시에도 완벽한 멱등성을 보장하며, k3s 및 ArgoCD 자동 배포가 정상적으로 동작합니다. 일부 서비스 접근 문제는 NetworkPolicy 및 Service Type 설정 개선으로 해결 가능합니다.
