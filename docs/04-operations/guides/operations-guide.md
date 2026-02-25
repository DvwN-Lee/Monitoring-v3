# Operations Guide

Monitoring-v3 Production 환경의 일상 운영 절차를 정리한다.

## 배포 상태 확인

### ArgoCD Application 동기화 확인

```bash
kubectl get app -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

기대 결과: 9개 Application 모두 `Synced` / `Healthy`.

| Application | 역할 |
|-------------|------|
| root-app | App of Apps 진입점 |
| titanium-prod | Application Namespace (4 Microservices + DB + Cache) |
| kube-prometheus-stack | Prometheus + Grafana Helm Chart |
| loki-stack | Loki + Promtail Helm Chart |
| istio-base | Istio CRD |
| istiod | Istio Control Plane |
| istio-ingressgateway | Istio Ingress Gateway |
| kiali | Service Mesh Dashboard |
| external-secrets-operator | Secret 관리 Operator |

### Pod 상태 확인

```bash
# 전체 Namespace Pod 상태
kubectl get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded

# titanium-prod Namespace 상세
kubectl get pods -n titanium-prod -o wide
```

titanium-prod의 Application Pod는 `2/2`(app + istio-proxy sidecar)를 유지해야 한다.

### Node 상태 확인

```bash
kubectl get nodes -o wide
kubectl top nodes
```

## 로그 조회

### kubectl 기반 로그 조회

```bash
# 특정 Service 로그
kubectl logs -n titanium-prod -l app=api-gateway -c api-gateway-container --tail=100

# 이전 Container 로그 (CrashLoopBackOff 등)
kubectl logs -n titanium-prod <POD_NAME> --previous

# 실시간 로그 Streaming
kubectl logs -n titanium-prod -l app=blog-service -c blog-service-container -f
```

### Loki LogQL 쿼리 (Grafana Explore)

Grafana (`http://<MASTER_IP>:31300/grafana/`) > Explore > Data source: Loki 선택.

```logql
# 특정 Namespace 전체 로그
{namespace="titanium-prod"}

# 특정 Service 로그
{namespace="titanium-prod", app="auth-service"}

# ERROR 레벨만 필터링
{namespace="titanium-prod"} |= "ERROR"

# JSON 파싱 후 필드 기반 필터링
{namespace="titanium-prod", app="blog-service"} | json | status_code >= 500

# 최근 1시간 에러 비율
sum(rate({namespace="titanium-prod"} |= "ERROR" [5m])) by (app)
```

## Metrics 모니터링

### Grafana Dashboard 접근

Grafana URL: `http://<MASTER_IP>:31300/grafana/`

주요 Dashboard:

| Dashboard | 용도 |
|-----------|------|
| Kubernetes / Compute Resources / Cluster | Cluster 전체 CPU/Memory 사용량 |
| Kubernetes / Compute Resources / Namespace | Namespace별 리소스 사용량 |
| Kubernetes / Compute Resources / Pod | Pod 단위 리소스 상세 |
| Kubernetes / Networking / Cluster | 네트워크 트래픽 |

### PromQL 쿼리 예시

Grafana > Explore > Data source: Prometheus 선택.

```promql
# Namespace별 CPU 사용량
sum(rate(container_cpu_usage_seconds_total{namespace="titanium-prod"}[5m])) by (pod)

# Namespace별 Memory 사용량
sum(container_memory_working_set_bytes{namespace="titanium-prod"}) by (pod)

# HTTP Request Rate (Istio 기반)
sum(rate(istio_requests_total{destination_service_namespace="titanium-prod"}[5m])) by (destination_service_name)

# HTTP Error Rate (5xx)
sum(rate(istio_requests_total{destination_service_namespace="titanium-prod", response_code=~"5.."}[5m])) by (destination_service_name)

# Request Latency P95 (Istio 기반)
histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{destination_service_namespace="titanium-prod"}[5m])) by (le, destination_service_name))
```

## Kiali Service Mesh 모니터링

Kiali URL: `http://<MASTER_IP>:31200/kiali/`

주요 확인 항목:

- **Overview**: Namespace별 상태 및 Istio Config 유효성
- **Graph**: Service 간 Traffic 흐름 시각화 (mTLS 상태 포함)
- **Workloads**: 각 Workload의 Health, Inbound/Outbound 트래픽
- **Istio Config**: VirtualService, DestinationRule, PeerAuthentication 설정 검증

## Backup 및 복구

### PostgreSQL Backup

```bash
# Pod 내에서 pg_dump 실행
kubectl exec -n titanium-prod prod-postgresql-0 -- \
  pg_dump -U postgres -d blogdb > backup_$(date +%Y%m%d).sql
```

### PostgreSQL 복구

```bash
# Backup 파일을 Pod로 복사 후 복원
kubectl cp backup_20260210.sql titanium-prod/prod-postgresql-0:/tmp/
kubectl exec -n titanium-prod prod-postgresql-0 -- \
  psql -U postgres -d blogdb -f /tmp/backup_20260210.sql
```

### etcd Snapshot (K3s)

```bash
# Master Node에서 실행
ssh -i ~/.ssh/titanium-key ubuntu@<MASTER_IP>

# K3s 내장 etcd snapshot
sudo k3s etcd-snapshot save --name manual-backup-$(date +%Y%m%d)

# Snapshot 확인
sudo k3s etcd-snapshot ls
```

### etcd 복구

```bash
# K3s etcd snapshot 복원
sudo systemctl stop k3s
sudo k3s server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<SNAPSHOT_NAME>
sudo systemctl start k3s
```

## Scale 조정

### HPA (Horizontal Pod Autoscaler) 확인

```bash
kubectl get hpa -n titanium-prod
```

### 수동 Replica 조정

```bash
# Deployment Replica 변경
kubectl scale deployment prod-api-gateway-deployment -n titanium-prod --replicas=3
```

### MIG (Managed Instance Group) Worker Node 조정

```bash
# 현재 Worker 수 확인
gcloud compute instance-groups managed describe <MIG_NAME> \
  --zone=asia-northeast3-a \
  --format="value(targetSize)"

# Worker Node 수 변경
gcloud compute instance-groups managed resize <MIG_NAME> \
  --zone=asia-northeast3-a \
  --size=3
```

Terraform을 통한 변경이 권장된다.

```hcl
# terraform.tfvars
worker_count = 3
```

```bash
terraform apply
```

## 인증서 및 Secret Rotation

Secret 관리 상세는 [Secret Management](../../secret-management.md) 문서를 참조한다.

### Secret Rotation 절차 요약

1. GCP Secret Manager에 새 Secret Version 추가
2. External Secrets Operator 자동 동기화 대기 (기본 1시간) 또는 수동 트리거
3. 관련 Pod Rolling Restart

```bash
# ESO 수동 동기화 트리거
kubectl annotate externalsecret prod-app-secrets -n titanium-prod \
  force-sync=$(date +%s) --overwrite

# Pod Rolling Restart
kubectl rollout restart deployment -n titanium-prod
```

## 리소스 정리

### 전체 Infrastructure 제거

```bash
cd terraform/environments/gcp
terraform destroy
```

### 특정 Application만 제거

```bash
# ArgoCD에서 Application 삭제
kubectl delete app <APP_NAME> -n argocd
```

## 관련 문서

- [Secret Management](../../secret-management.md)
- [Troubleshooting](../../05-troubleshooting/README.md)
- [Operational Changes](../../operational-changes.md)
