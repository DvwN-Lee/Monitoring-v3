# Titanium Monitoring Platform Architecture

## 개요

Titanium은 GCP 기반 Kubernetes(K3s) 환경에서 운영되는 Microservice 기반 Monitoring Platform이다. Infrastructure as Code(Terraform), GitOps(ArgoCD), Service Mesh(Istio)를 통해 End-to-End 자동화를 구현한다.

## 기술 스택

| 계층 | 기술 |
|------|------|
| Cloud Provider | Google Cloud Platform (GCP) |
| Kubernetes | K3s v1.31 |
| IaC | Terraform |
| GitOps | ArgoCD v3.2.3 |
| Service Mesh | Istio v1.24.2 |
| Monitoring | Prometheus + Loki + Grafana |
| Secret Management | External Secrets Operator + GCP Secret Manager |
| Container Registry | GitHub Container Registry (ghcr.io) |
| CI/CD | GitHub Actions |

---

## 시스템 아키텍처

```mermaid
flowchart TB
    subgraph Internet
        Client[Client]
    end

    subgraph GCP["Google Cloud Platform"]
        subgraph VPC["VPC Network"]
            LB[GCP Load Balancer<br/>TCP Proxy]

            subgraph K3s["K3s Cluster"]
                subgraph istio-system["istio-system NS"]
                    IGW[Istio IngressGateway<br/>NodePort 31080/31443]
                end

                subgraph titanium-prod["titanium-prod NS"]
                    Services[Microservices]
                end

                subgraph monitoring["monitoring NS"]
                    Mon[Prometheus + Loki + Grafana]
                end

                subgraph argocd-ns["argocd NS"]
                    ArgoCD[ArgoCD]
                end
            end
        end

        SM[GCP Secret Manager]
    end

    Client -->|HTTPS/443| LB
    LB -->|NodePort| IGW
    IGW --> Services
    SM -.->|External Secrets| Services
```

---

## Infrastructure 아키텍처

### GCP 리소스 구성

```mermaid
flowchart TB
    subgraph GCP["GCP Project"]
        subgraph VPC["VPC Network (titanium-vpc)"]
            Subnet["Subnet<br/>10.0.1.0/24"]

            subgraph FW["Firewall Rules"]
                FW1[allow-internal]
                FW2[allow-ssh]
                FW3[allow-k3s-api :6443]
                FW4[allow-nodeport :30000-32767]
            end
        end

        subgraph Compute["Compute Engine"]
            Server["k3s-server<br/>(Control Plane)"]
            Agent1["k3s-agent-1<br/>(Worker)"]
            Agent2["k3s-agent-2<br/>(Worker)"]
        end

        LB["Cloud Load Balancer"]
        SM["Secret Manager<br/>titanium-secrets"]
    end

    Subnet --> Server
    Subnet --> Agent1
    Subnet --> Agent2
    LB --> Server
    LB --> Agent1
    LB --> Agent2
```

### K3s Cluster 구성

| 노드 역할 | 스펙 | 수량 |
|----------|------|------|
| Server (Control Plane) | e2-medium (2 vCPU, 4GB) | 1 |
| Agent (Worker) | e2-medium (2 vCPU, 4GB) | 2 |

### Bootstrap 자동화 흐름

```mermaid
sequenceDiagram
    participant TF as Terraform
    participant VM as GCP VM
    participant K3s as K3s Cluster
    participant Argo as ArgoCD

    TF->>VM: 1. VM 생성
    VM->>K3s: 2. k3s-server.sh 실행
    K3s->>K3s: 3. K3s 설치
    K3s->>Argo: 4. ArgoCD 설치
    Argo->>Argo: 5. Root App 등록
    Argo->>K3s: 6. Infrastructure/App 동기화
```

---

## Application 아키텍처

### Microservice 구성

```mermaid
flowchart TB
    subgraph External
        Client[Client]
    end

    subgraph istio-system
        IGW[Istio IngressGateway]
    end

    subgraph titanium-prod["titanium-prod Namespace"]
        subgraph Services["Application Services"]
            API[api-gateway<br/>Go :8000]
            Auth[auth-service<br/>Python :8002]
            User[user-service<br/>Python :8001]
            Blog[blog-service<br/>Python :8005]
        end

        subgraph Data["Data Stores"]
            PG[(PostgreSQL<br/>:5432)]
            Redis[(Redis<br/>:6379)]
        end
    end

    Client --> IGW
    IGW -->|/api/*| API
    IGW -->|/api/users| User
    IGW -->|/api/login, /api/auth| Auth
    IGW -->|/blog, /| Blog

    API --> Auth
    API --> User
    API --> Blog

    Auth --> User
    Auth --> Redis
    Blog --> Auth
    Blog --> PG
    User --> PG
    User --> Redis
```

### Service 상세

| Service | 기술 | 포트 | 역할 |
|---------|------|------|------|
| api-gateway | Go (Gin) | 8000 | API 라우팅, Rate Limiting |
| auth-service | Python (FastAPI) | 8002 | JWT 인증, 로그인 |
| user-service | Python (FastAPI) | 8001 | 사용자 CRUD |
| blog-service | Python (FastAPI) | 8005 | 블로그 CRUD, 프론트엔드 |
| postgresql | PostgreSQL 15 | 5432 | 영구 데이터 저장 |
| redis | Redis 7 | 6379 | JWT Token 캐싱 |

### Istio 라우팅 (VirtualService)

| 경로 | 대상 Service |
|------|-------------|
| `/blog/*` | blog-service:8005 |
| `/api/users/*` | user-service:8001 |
| `/api/login` | auth-service:8002 |
| `/api/auth/*` | auth-service:8002 |
| `/api/*` (fallback) | api-gateway:8000 |
| `/` | blog-service:8005 |

---

## GitOps 배포 아키텍처

### App of Apps 패턴

```mermaid
flowchart TB
    subgraph ArgoCD["ArgoCD (argocd NS)"]
        Root[root-app<br/>App of Apps]

        subgraph InfraApps["Infrastructure Apps"]
            Istiod[istiod]
            Gateway[istio-ingressgateway]
            Prom[prometheus]
            Loki[loki-stack]
            ESO[external-secrets]
        end

        subgraph AppApps["Application Apps"]
            Titanium[titanium-prod]
        end
    end

    subgraph GitHub["GitHub Repository"]
        AppsInfra["apps/infrastructure/"]
        AppsApp["apps/applications/"]
        K8sManifests["k8s-manifests/overlays/gcp/"]
    end

    Root --> InfraApps
    Root --> AppApps

    InfraApps -.->|sync| AppsInfra
    AppApps -.->|sync| AppsApp
    Titanium -.->|sync| K8sManifests
```

### 디렉토리 구조

```
Monitoring-v3/
├── apps/                          # ArgoCD Application 정의
│   ├── root-app.yaml              # Root Application (진입점)
│   ├── infrastructure/            # Infrastructure Apps
│   │   ├── argocd.yaml
│   │   ├── istiod.yaml
│   │   ├── istio-ingressgateway.yaml
│   │   ├── prometheus.yaml
│   │   ├── loki-stack.yaml
│   │   └── external-secrets.yaml
│   └── applications/              # Application Apps
│       └── titanium-prod.yaml
├── k8s-manifests/                 # Kubernetes 리소스 정의
│   ├── base/                      # 공통 리소스
│   └── overlays/
│       └── gcp/                   # GCP 환경 Overlay
└── terraform/                     # Infrastructure as Code
    └── environments/
        └── gcp/
```

### CI/CD 파이프라인

```mermaid
flowchart LR
    subgraph Dev["Development"]
        Developer[Developer]
    end

    subgraph GitHub
        Repo[Repository]
        Actions[GitHub Actions<br/>CI Pipeline]
        GHCR[GHCR<br/>Container Registry]
    end

    subgraph K3s["K3s Cluster"]
        ArgoCD[ArgoCD<br/>GitOps]
        Pods[Application Pods]
    end

    Developer -->|git push| Repo
    Repo -->|trigger| Actions
    Actions -->|push image| GHCR
    Repo -->|webhook| ArgoCD
    GHCR -->|pull image| Pods
    ArgoCD -->|sync| Pods
```

---

## 네트워크 아키텍처

### Zero Trust NetworkPolicy

모든 Pod에 기본 Deny 정책 적용 후, 필요한 통신만 명시적 허용.

```mermaid
flowchart TB
    subgraph istio-system
        IGW[Istio IngressGateway]
        Istiod[Istiod]
    end

    subgraph monitoring
        Prom[Prometheus]
    end

    subgraph kube-system
        DNS[kube-dns :53]
    end

    subgraph titanium-prod["titanium-prod Namespace"]
        API[api-gateway :8000]
        Auth[auth-service :8002]
        User[user-service :8001]
        Blog[blog-service :8005]
        PG[(PostgreSQL :5432)]
        Redis[(Redis :6379)]
    end

    IGW -->|허용| API
    IGW -->|허용| Auth
    IGW -->|허용| User
    IGW -->|허용| Blog

    API -->|허용| Auth
    API -->|허용| User
    API -->|허용| Blog

    Auth -->|허용| User
    Auth -->|허용| Redis

    Blog -->|허용| Auth
    Blog -->|허용| PG
    Blog -->|허용| Redis

    User -->|허용| PG
    User -->|허용| Redis

    Prom -.->|scrape| API
    Prom -.->|scrape| Auth
    Prom -.->|scrape| User
    Prom -.->|scrape| Blog

    API -.->|DNS| DNS
    Auth -.->|DNS| DNS
    User -.->|DNS| DNS
    Blog -.->|DNS| DNS

    API -.->|xDS| Istiod
    Auth -.->|xDS| Istiod
    User -.->|xDS| Istiod
    Blog -.->|xDS| Istiod
```

### 허용된 통신 경로

| Source | Destination | Port | 용도 |
|--------|-------------|------|------|
| istio-ingressgateway | api-gateway | 8000 | 외부 트래픽 |
| istio-ingressgateway | *-service | 800* | 직접 라우팅 |
| api-gateway | auth/user/blog-service | 800* | API 프록시 |
| auth-service | user-service | 8001 | 사용자 조회 |
| auth-service | redis | 6379 | JWT 저장 |
| user/blog-service | postgresql | 5432 | 데이터 저장 |
| 모든 Pod | kube-dns | 53/UDP | DNS 조회 |
| 모든 Pod | istiod | 15012, 15010 | Istio Control Plane |

---

## 관측성 (Observability)

### Monitoring Stack

```mermaid
flowchart TB
    subgraph titanium-prod["titanium-prod Namespace"]
        subgraph Pods["Application Pods"]
            App1[api-gateway<br/>/metrics]
            App2[auth-service<br/>/metrics]
            App3[user-service<br/>/metrics]
            App4[blog-service<br/>/metrics]
        end

        subgraph Sidecars["Envoy Sidecars"]
            Envoy[:15090/stats]
        end
    end

    subgraph monitoring["monitoring Namespace"]
        SM[ServiceMonitor<br/>autodiscovery]
        Prom[Prometheus]
        Loki[Loki]
        Promtail[Promtail]
        Grafana[Grafana<br/>Dashboard]
    end

    App1 --> SM
    App2 --> SM
    App3 --> SM
    App4 --> SM
    Envoy --> SM
    SM --> Prom

    Pods -->|logs| Promtail
    Promtail --> Loki

    Prom -->|PromQL| Grafana
    Loki -->|LogQL| Grafana
```

### 수집 메트릭

| 메트릭 유형 | 소스 | 용도 |
|------------|------|------|
| Application Metrics | ServiceMonitor | 요청 수, 응답 시간, 에러율 |
| Istio Metrics | Envoy Sidecar (15090) | Service Mesh 트래픽 |
| Kubernetes Metrics | kube-state-metrics | Pod/Node 상태 |
| Node Metrics | node-exporter | CPU, Memory, Disk |
| Application Logs | Promtail | 중앙 집중 로그 |

---

## 보안 아키텍처

### 계층별 보안

| 계층 | 보안 메커니즘 |
|------|-------------|
| Network | GCP Firewall, Kubernetes NetworkPolicy |
| Transport | Istio mTLS (STRICT mode) |
| Authentication | JWT (auth-service) |
| Secret Management | External Secrets + GCP Secret Manager |
| Container | Non-root user, Read-only filesystem |

### Secret 관리 흐름

```mermaid
flowchart LR
    subgraph GCP
        SM[GCP Secret Manager<br/>titanium-secrets]
    end

    subgraph K3s["K3s Cluster"]
        ESO[External Secrets<br/>Operator]
        ES[ExternalSecret CR]
        Secret[Kubernetes Secret<br/>prod-app-secrets]
        Pod[Application Pod]
    end

    SM -->|fetch| ESO
    ES -->|define mapping| ESO
    ESO -->|create| Secret
    Secret -->|envFrom| Pod
```

### mTLS 통신

```mermaid
flowchart LR
    subgraph Pod1["Pod A"]
        App1[Application]
        Envoy1[Envoy Sidecar]
    end

    subgraph Pod2["Pod B"]
        Envoy2[Envoy Sidecar]
        App2[Application]
    end

    subgraph istio-system
        Istiod[Istiod<br/>Certificate Authority]
    end

    App1 -->|plaintext| Envoy1
    Envoy1 <-->|mTLS| Envoy2
    Envoy2 -->|plaintext| App2

    Istiod -.->|issue cert| Envoy1
    Istiod -.->|issue cert| Envoy2
```

---

## 관련 문서

- [ADR 목록](adr/README.md): Architecture Decision Records
- [IaC 트러블슈팅](../IaC-TROUBLESHOOTING.md): Infrastructure 문제 해결
- [트러블슈팅](../TROUBLESHOOTING.md): 일반 문제 해결
- [Secret 관리](../secret-management.md): Secret 관리 가이드
