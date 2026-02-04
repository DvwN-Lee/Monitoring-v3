# GCP Production 환경 데모

GCP Production 환경에 배포된 K3s Cluster의 Application 동작 검증 데모.

## 환경 정보

| 항목 | 값 |
|------|-----|
| Project ID | titanium-k3s-20260123 |
| Region | asia-northeast3 |
| Master IP | 34.22.103.1 |
| K3s Version | v1.31.4+k3s1 |
| 데모 일시 | 2026-02-03 |

## 1. Blog Application CRUD 테스트

### 1.1 Main Page 접속

Blog Application의 Main Page. 로그인 전 상태에서 "로그인" 버튼이 표시됨.

![Blog Main](01-blog-main.png)

**Endpoint**: `http://34.22.103.1:31080/blog/`

### 1.2 회원가입

신규 계정 생성을 위한 회원가입 Modal.

![Signup Modal](02-signup-modal.png)

테스트 계정 정보 입력 후 가입 진행.

![Signup Filled](03-signup-filled.png)

회원가입 완료 후 자동 로그인.

![Signup Success](04-signup-success.png)

### 1.3 로그인 확인

로그인 완료 상태. Header에 "글쓰기", "로그아웃" 버튼 표시.

![Login Success](05-login-success.png)

### 1.4 Create - 게시글 작성

"글쓰기" 버튼 클릭 시 게시글 작성 Form 표시.

![Write Form](06-write-form.png)

게시글 내용 입력.
- 제목: GCP Production 환경 배포 완료
- 카테고리: 기술 스택
- 내용: Markdown 형식 지원

![Post Create Filled](07-post-create-filled.png)

### 1.5 Read - 게시글 조회

저장 완료 후 게시글 상세 페이지. Markdown이 HTML로 렌더링됨.

![Post Created](08-post-created.png)

### 1.6 Update - 게시글 수정

"수정" 버튼 클릭 시 기존 내용이 Form에 로드됨.

![Post Edit Form](09-post-edit-form.png)

제목 수정: "(수정됨)" 텍스트 추가.

![Post Edit Modified](10-post-edit-modified.png)

수정 완료 후 변경된 제목 확인.

![Post Updated](11-post-updated.png)

### 1.7 Delete - 게시글 삭제

"삭제" 버튼 클릭 시 확인 Dialog 표시.

![Post Delete Confirm](12-post-delete-confirm.png)

삭제 완료 후 Main Page로 이동. "게시물이 없습니다" 메시지 표시.

![Post Deleted](13-post-deleted.png)

## 2. ArgoCD Dashboard

### 2.1 로그인 페이지

ArgoCD UI 접속 화면.

![ArgoCD Login](14-argocd-login.png)

**Endpoint**: `http://34.22.103.1:30080`

### 2.2 Applications 현황

9개 Application 모두 **Synced** 및 **Healthy** 상태.

![ArgoCD Dashboard](15-argocd-dashboard.png)

| Application | Status | Repository |
|-------------|--------|------------|
| root-app | Synced, Healthy | github.com/DvwN-Lee/Monitoring-v3 |
| titanium-prod | Synced, Healthy | github.com/DvwN-Lee/Monitoring-v3 |
| kube-prometheus-stack | Synced, Healthy | prometheus-community Helm |
| loki-stack | Synced, Healthy | grafana Helm |
| istiod | Synced, Healthy | istio-release Helm |
| istio-base | Synced, Healthy | istio-release Helm |
| istio-ingressgateway | Synced, Healthy | istio-release Helm |
| kiali | Synced, Healthy | kiali Helm |
| external-secrets-operator | Synced, Healthy | external-secrets Helm |

## 3. Grafana Dashboard

### 3.1 로그인 페이지

Grafana UI 접속 화면.

![Grafana Login](16-grafana-login.png)

**Endpoint**: `http://34.22.103.1:31300/grafana/`

### 3.2 Home Page

Grafana 초기 화면. Data source 및 Dashboard 설정 완료 상태.

![Grafana Home](17-grafana-home.png)

### 3.3 Dashboards 목록

kube-prometheus-stack에서 제공하는 Kubernetes Monitoring Dashboard 목록.

![Grafana Dashboards](18-grafana-dashboards.png)

주요 Dashboard:
- CoreDNS
- etcd
- Kubernetes / API server
- Kubernetes / Compute Resources / Cluster
- Kubernetes / Compute Resources / Namespace
- Kubernetes / Compute Resources / Pod
- Kubernetes / Networking / Cluster
- Kubernetes / Persistent Volumes

### 3.4 Kubernetes Cluster 리소스 현황

Cluster 전체 리소스 사용량 Dashboard.

![Grafana K8s Cluster](19-grafana-k8s-cluster.png)

| Metric | Value |
|--------|-------|
| CPU Utilisation | 10.8% |
| CPU Requests Commitment | 48.5% |
| Memory Utilisation | 30.3% |
| Memory Requests Commitment | 27.9% |

Namespace별 리소스 사용량:
- monitoring: CPU 0.128, Memory 1.00 GiB
- titanium-prod: CPU 0.061, Memory 600 MiB
- argocd: CPU 0.052, Memory 512 MiB
- istio-system: CPU 0.016, Memory 136 MiB

## 4. Kiali Dashboard (Service Mesh)

### 4.1 Overview Page

Kiali Overview 페이지. Cluster 내 모든 Namespace 표시.

![Kiali Overview](20-kiali-overview.png)

**Endpoint**: `http://34.22.103.1:31200/kiali/console/overview`

표시된 Namespace:
- argocd
- default
- external-secrets
- istio-system (Control plane)
- monitoring
- titanium-prod (Istio injection enabled)

#### Namespace별 Istio Sidecar Injection 상태

| Namespace | istio-injection | Istio Config | Traffic | 설명 |
|-----------|-----------------|--------------|---------|------|
| titanium-prod | `enabled` | mTLS 활성화 | 표시됨 | 비즈니스 애플리케이션 |
| istio-system | `enabled` | Control Plane | N/A | Istio 자체 컴포넌트 |
| argocd | 미설정 | N/A | No inbound | GitOps 도구, Mesh 불필요 |
| monitoring | 미설정 | N/A | No inbound | Prometheus/Grafana 스택 |
| external-secrets | 미설정 | N/A | No inbound | 인프라 컴포넌트 |
| default | 미설정 | N/A | No inbound | 기본 namespace, 미사용 |

**N/A 및 No inbound traffic 표시 원인**:
- `istio-injection: enabled` label이 없는 namespace에는 Istio sidecar가 주입되지 않음
- Sidecar가 없으면 Kiali에서 트래픽 모니터링 및 Istio 설정 표시 불가
- 이는 의도된 설계로, 인프라 컴포넌트는 Service Mesh 오버헤드 없이 운영

**실제 Pod 상태 비교**:
```bash
# titanium-prod: 2/2 (app + istio-proxy sidecar)
prod-api-gateway-deployment-xxx    2/2     Running

# argocd: 1/1 (app only, no sidecar)
argocd-server-xxx                  1/1     Running
```

### 4.2 Mesh Topology

Service Mesh 구성 요소 토폴로지.

![Kiali Mesh](21-kiali-mesh.png)

| Component | Version |
|-----------|---------|
| Kubernetes | v1.31.4+k3s1 |
| istiod | 1.24.2 |
| Kiali | v2.4.0 |
| Data Plane | 2 namespaces |

### 4.3 Traffic Graph

titanium-prod Namespace의 Service 간 Traffic 흐름 시각화.

![Kiali Traffic Graph](22-kiali-traffic-graph.png)

Traffic 흐름:
- `istio-ingressgateway` -> `api-gateway` -> 각 서비스
- `traffic-generator` -> `auth-service`, `user-service`, `blog-service`
- 모든 서비스 간 mTLS 암호화 통신

### 4.4 Workloads 현황

titanium-prod Namespace의 모든 Workload 상태.

![Kiali Workloads](23-kiali-workloads.png)

| Workload | Type | Status | Istio Config |
|----------|------|--------|--------------|
| prod-api-gateway-deployment | Deployment | Healthy | AP, PA |
| prod-auth-service-deployment | Deployment | Healthy | AP, PA |
| prod-blog-service-deployment | Deployment | Healthy | AP, PA |
| prod-postgresql | StatefulSet | Healthy | AP, PA (mTLS disabled) |
| prod-redis-deployment | Deployment | Healthy | AP, PA (mTLS disabled) |
| prod-user-service-deployment | Deployment | Healthy | AP, PA |

- AP: AuthorizationPolicy
- PA: PeerAuthentication

### 4.5 Istio Sidecar Injection 현황

titanium-prod Namespace의 Pod에 Istio Sidecar(istio-proxy)가 주입됨:

| Workload | Containers |
|----------|------------|
| api-gateway | istio-proxy, api-gateway-container |
| auth-service | istio-proxy, auth-service-container |
| blog-service | istio-proxy, blog-service-container |
| user-service | istio-proxy, user-service-container |
| redis | istio-proxy, redis-container |
| traffic-generator | istio-proxy, traffic-generator |

## 검증 결과 요약

| 항목 | 상태 |
|------|------|
| Blog Application CRUD | 정상 동작 |
| ArgoCD GitOps | 9개 App Synced & Healthy |
| Grafana Monitoring | Dashboard 정상 표시 |
| Kiali Service Mesh | Traffic Graph/Workloads 정상 표시 |
| Cluster Resource | CPU 10.8%, Memory 30.3% 사용 |

## Resolved Issues

### Kiali Workload/Traffic 조회 오류 (해결됨)

**이전 증상**:
Kiali에서 Workload 및 Traffic Graph 조회 시 다음 오류 발생:
```
istio APIs and resources are not present in cluster [Kubernetes]
```

**원인**:
- Single-cluster 환경에서 multi-cluster 자동 감지 설정이 활성화됨
- `clustering.autodetect_secrets.enabled: true` 설정으로 인해 multi-cluster 모드로 초기화

**해결**:
- `kiali-config.yaml`에서 `clustering.autodetect_secrets.enabled: false`로 변경
- ArgoCD를 통한 자동 배포 및 Kiali Pod 재시작
