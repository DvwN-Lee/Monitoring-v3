# Terraform 인프라 상태 보고서

**점검 일시:** 2026-01-31
**환경:** GCP `titanium-k3s-20260123`
**Terraform Version:** state 기준 18개 리소스 관리 중
**Drift 상태:** `No changes` (실제 인프라와 IaC 설정 완전 일치)

---

## 관리 리소스 현황

### Network (3개)

| 리소스 | 이름 | 상태 | 비고 |
|--------|------|------|------|
| `google_compute_network` | `titanium-k3s-vpc` | 정상 | Project VPC |
| `google_compute_subnetwork` | `titanium-k3s-subnet` | 정상 | `asia-northeast3` Region |
| `google_compute_address` | `titanium-k3s-master-ip` | 정상 | Static IP `34.64.171.141` |

### Firewall (5개)

| 리소스 | 허용 포트 | Source Range | 상태 |
|--------|-----------|--------------|------|
| `allow_ssh` | TCP:22 | IAP CIDR + Admin IP | 정상 |
| `allow_k8s_api` | TCP:6443 | Admin IP | 정상 |
| `allow_dashboards` | TCP:80,443,30000-32767 | Admin IP | 정상 |
| `allow_internal` | ALL | Subnet CIDR (`10.128.0.0/20`) | 정상 |
| `allow_health_check` | TCP:10250 | GCP Health Check CIDR | 정상 |

Admin IP는 `terraform apply` 실행 시 `api.ipify.org`를 통해 자동 감지됩니다.
현재 감지된 IP: `112.218.39.251/32`

### Compute (4개)

| 리소스 | 이름 | Spec | 상태 |
|--------|------|------|------|
| `google_compute_instance` | `titanium-k3s-master` | e2-medium | Running |
| `google_compute_instance_template` | `titanium-k3s-worker` | e2-standard-2, Preemptible | 정상 |
| `google_compute_instance_group_manager` | `titanium-k3s-worker-mig` | Managed Instance Group | 정상 |
| `google_compute_health_check` | Worker Autohealing | TCP:10250 | 정상 |

### IAM (3개)

| 리소스 | 이름/역할 | 상태 |
|--------|-----------|------|
| `google_service_account` | `titanium-k3s-sa` | 정상 |
| `google_project_iam_member` | `roles/logging.logWriter` | 정상 |
| `google_project_iam_member` | `roles/monitoring.metricWriter` | 정상 |

### 기타 (3개)

| 리소스 | 용도 | 상태 |
|--------|------|------|
| `random_password` | k3s Cluster token | 정상 |
| `null_resource` | kubeconfig 템플릿 생성 | 정상 |
| `data.http` | Admin IP 자동 감지 (`api.ipify.org`) | 정상 |

---

## Cluster 접속 정보

| 서비스 | Endpoint |
|--------|----------|
| Kubernetes API | `https://34.64.171.141:6443` |
| ArgoCD UI | `http://34.64.171.141:30080` |
| Grafana Dashboard | `http://34.64.171.141:31300` |
| Kiali Dashboard | `http://34.64.171.141:31200` |

---

## 자동화 범위

| 항목 | 방식 | 설명 |
|------|------|------|
| Admin IP Firewall | `data "http"` + `ipify.org` | `terraform apply` 시 현재 IP 자동 감지 및 Firewall 반영 |
| k3s Bootstrap | Master startup script | k3s 설치 -> Namespace 생성 -> Secret 주입 -> ArgoCD 설치 -> Root App 배포 |
| Worker Scaling | MIG + Preemptible + Autohealing | Health Check 실패 시 자동 교체, Preemptible 선점 시 자동 재생성 |
| Application 배포 | ArgoCD App of Apps | Git repo (`k8s-manifests/overlays/gcp`) 변경 시 자동 sync |
| Secret 관리 | External Secrets Operator | GCP Secret Manager -> ClusterSecretStore -> ExternalSecret -> K8s Secret |
| kubeconfig | `make kubeconfig` | SSH 접속 후 k3s kubeconfig 자동 추출 및 로컬 저장 |

---

## 금일 수행 작업 및 Troubleshooting

### 1. Dead Node 정리

**문제:** Worker node `titanium-k3s-worker-kr9d-80e30f4e`가 `NotReady` 상태로 장기 체류.
해당 Node에 PostgreSQL Pod과 `local-path` PVC가 bound되어 있어, PostgreSQL이 `Terminating`에 걸리고 blog-service/user-service가 DB 연결 실패로 `CrashLoopBackOff` 발생.

**원인:** Preemptible Worker VM이 선점(preemption)되어 종료되었으나, 해당 Node의 k3s agent 등록이 Cluster에 남아있었음.

**해결:**
```bash
# 1. Terminating PostgreSQL Pod 강제 삭제
kubectl delete pod prod-postgresql-0 -n titanium-prod --force --grace-period=0

# 2. Dead Node에 bound된 local-path PVC 삭제
kubectl delete pvc prod-postgresql-pvc -n titanium-prod --force --grace-period=0

# 3. 새 PVC 생성 (local-path StorageClass)
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prod-postgresql-pvc
  namespace: titanium-prod
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 10Gi
EOF

# 4. PostgreSQL 정상 기동 확인 후 user-service rollout restart
kubectl rollout restart deployment prod-user-service-deployment -n titanium-prod

# 5. Dead Node drain 및 삭제
kubectl drain titanium-k3s-worker-kr9d-80e30f4e --ignore-daemonsets --delete-emptydir-data --force --grace-period=0
kubectl delete node titanium-k3s-worker-kr9d-80e30f4e
```

**결과:** 전체 서비스 정상 복구. DB 데이터는 초기화됨 (dead node의 local storage 복구 불가).

### 2. Firewall IP 변경

**문제:** 관리자 IP가 `112.150.249.93`에서 `112.218.39.251`로 변경되어 SSH 및 k8s API 접근 불가.

**해결:** `gcloud compute firewall-rules update`로 긴급 적용 후, `terraform plan`으로 drift 없음 확인.
Terraform은 `data "http"` provider로 현재 IP를 자동 감지하므로, `terraform apply` 실행만으로 Firewall rule이 자동 업데이트됨.

### 3. k3s Master VM Reset

**문제:** Master VM의 Serial console log가 1월 25일에서 중단. VM STATUS는 `RUNNING`이었으나 실제 OS가 hang 상태.

**해결:**
```bash
gcloud compute instances reset titanium-k3s-master --zone=asia-northeast3-a --project=titanium-k3s-20260123
```

Reset 후 k3s 서비스 자동 복구 확인.

---

## 현재 Cluster Node 상태

| Node | Role | Status | Version | 비고 |
|------|------|--------|---------|------|
| `titanium-k3s-master` | control-plane | Ready | v1.34.3+k3s1 | e2-medium |
| `titanium-k3s-worker-kr9d-006234f4` | worker | Ready | v1.34.3+k3s1 | MIG Preemptible |

---

## 현재 Service 상태

| Service | Pod 수 | Ready | 비고 |
|---------|--------|-------|------|
| api-gateway | 2 | 2/2 Running | 정상 |
| auth-service | 2 | 2/2 Running | 정상 |
| blog-service | 2 | 2/2 Running | 정상 |
| user-service | 2 | 2/2 Running | 정상 |
| postgresql | 1 | 1/1 Running | StatefulSet, local-path PVC |
| redis | 1 | 2/2 Running | 정상 |
| ExternalSecret | - | SecretSynced | GCP Secret Manager 연동 정상 |
| ClusterSecretStore | - | Valid | `prod-gcpsm-secret-store` |
