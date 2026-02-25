# Demo Scenario

Monitoring-v3 프로젝트의 구조화된 데모 시나리오. 전체 소요 시간은 약 20-25분이다.

## 사전 준비

| 항목 | 설명 |
|------|------|
| 접속 환경 | `admin_cidrs`에 현재 IP가 등록되어 있어야 함 |
| ArgoCD 로그인 정보 | admin / 초기 Password |
| Grafana 로그인 정보 | admin / `TF_VAR_grafana_admin_password` |
| Browser | Chrome 또는 Firefox 권장 |

### 접속 URL 확인

```bash
MASTER_IP=$(terraform -chdir=terraform/environments/gcp output -raw master_external_ip)
echo "Blog:    http://${MASTER_IP}:31080/blog/"
echo "ArgoCD:  http://${MASTER_IP}:30080"
echo "Grafana: http://${MASTER_IP}:31300/grafana/"
echo "Kiali:   http://${MASTER_IP}:31200/kiali/"
```

---

## Part 1: Infrastructure Overview (3분)

### 1.1 Terraform 리소스 확인

```bash
cd terraform/environments/gcp
terraform output
```

확인 항목:
- Master/Worker IP
- VPC, Subnet 정보
- Firewall Rules

### 1.2 K3s Cluster 상태

```bash
ssh -i ~/.ssh/titanium-key ubuntu@${MASTER_IP} "sudo kubectl get nodes -o wide"
```

확인 항목:
- Node 3개 (1 Master + 2 Workers) Ready 상태
- K3s Version: v1.31.4+k3s1

### 1.3 Namespace 구조

```bash
ssh -i ~/.ssh/titanium-key ubuntu@${MASTER_IP} "sudo kubectl get ns"
```

확인 항목: `argocd`, `istio-system`, `monitoring`, `titanium-prod`, `external-secrets`

---

## Part 2: GitOps - ArgoCD (4분)

### 2.1 ArgoCD Dashboard 접속

URL: `http://<MASTER_IP>:30080`

확인 항목:
- 9개 Application 전체 `Synced` & `Healthy`
- App of Apps 계층 구조 (root-app → infrastructure + applications)

참고 스크린샷: [ArgoCD Dashboard](../demo/15-argocd-dashboard.png)

### 2.2 Application 상세

`titanium-prod` Application 클릭:
- Resource Tree 확인 (Deployment, Service, ConfigMap, Secret, HPA 등)
- Sync 상태 및 최근 Sync 시간
- Health Check 결과

### 2.3 GitOps 흐름 설명

```
Developer Push → GitHub Actions CI (Test + Build + Push Image)
→ CD Pipeline (Image Tag 업데이트)
→ ArgoCD 감지 → K8s 자동 배포
```

---

## Part 3: Application CRUD (5분)

### 3.1 Blog Main Page

URL: `http://<MASTER_IP>:31080/blog/`

참고 스크린샷: [Blog Main](../demo/01-blog-main.png)

### 3.2 회원가입 및 로그인

1. "회원가입" 클릭
2. 사용자 정보 입력 (username, email, password)
3. 가입 완료 후 로그인

참고 스크린샷: [Signup](../demo/02-signup-modal.png), [Login Success](../demo/05-login-success.png)

### 3.3 게시글 CRUD

1. **Create**: "글쓰기" → 제목, 카테고리, 내용(Markdown) 입력 → 저장
2. **Read**: 작성된 게시글 상세 페이지 확인 (Markdown → HTML 렌더링)
3. **Update**: "수정" 버튼 → 내용 변경 → 저장
4. **Delete**: "삭제" 버튼 → 확인 Dialog → 삭제 완료

참고 스크린샷: [Create](../demo/07-post-create-filled.png), [Read](../demo/08-post-created.png), [Update](../demo/10-post-edit-modified.png), [Delete](../demo/12-post-delete-confirm.png)

---

## Part 4: Observability (6분)

### 4.1 Grafana - Cluster Metrics

URL: `http://<MASTER_IP>:31300/grafana/`

1. Dashboard > Browse > "Kubernetes / Compute Resources / Cluster"
2. 확인 항목:
   - CPU Utilisation, Memory Utilisation
   - Namespace별 리소스 사용량

참고 스크린샷: [Grafana K8s Cluster](../demo/19-grafana-k8s-cluster.png)

### 4.2 Grafana - Loki 로그 조회

1. Explore > Data source: Loki 선택
2. 쿼리 예시:

```logql
{namespace="titanium-prod", app="blog-service"}
```

3. 방금 수행한 CRUD 작업 로그 확인

### 4.3 Kiali - Service Mesh

URL: `http://<MASTER_IP>:31200/kiali/`

1. **Overview**: Namespace별 상태 확인
2. **Graph**: titanium-prod Namespace 선택
   - Traffic 흐름: `istio-ingressgateway` → `api-gateway` → 각 Service
   - mTLS 상태 (자물쇠 아이콘)
3. **Workloads**: 각 Workload Health 및 Istio Config

참고 스크린샷: [Traffic Graph](../demo/22-kiali-traffic-graph.png), [Workloads](../demo/23-kiali-workloads.png)

---

## Part 5: Security (4분)

### 5.1 Istio mTLS 확인

```bash
ssh -i ~/.ssh/titanium-key ubuntu@${MASTER_IP} \
  "sudo kubectl get peerauthentication -n titanium-prod -o yaml"
```

확인 항목: `mode: STRICT`

### 5.2 Zero Trust NetworkPolicy

```bash
ssh -i ~/.ssh/titanium-key ubuntu@${MASTER_IP} \
  "sudo kubectl get networkpolicy -n titanium-prod"
```

확인 항목: Default Deny + Service별 Explicit Allow

### 5.3 External Secrets 상태

```bash
ssh -i ~/.ssh/titanium-key ubuntu@${MASTER_IP} \
  "sudo kubectl get externalsecret -n titanium-prod"
```

확인 항목: `STATUS = SecretSynced`

### 5.4 mTLS 통신 검증 (선택)

```bash
# Pod 내부에서 Service 호출 시 mTLS 적용 확인
ssh -i ~/.ssh/titanium-key ubuntu@${MASTER_IP} \
  "sudo kubectl exec -n titanium-prod deploy/prod-api-gateway-deployment -c istio-proxy -- \
   curl -s http://prod-auth-service:8002/health"
```

---

## Part 6: Testing (3분)

### 6.1 Infrastructure Test (Terratest)

```bash
cd terraform/environments/gcp/test
go test -v -run "TestTerraform" -timeout 10m
```

Layer 0-1.5 (Static Validation, Plan Unit, Plan Deep Analysis)는 비용 없이 실행 가능.

### 6.2 E2E Test (k6)

```bash
k6 run tests/e2e/e2e-test.js -e BASE_URL=http://${MASTER_IP}:31080
```

7개 테스트 항목 전체 통과 확인.

---

## 검증 결과 요약

| 항목 | 상태 |
|------|------|
| Blog Application CRUD | 정상 동작 |
| ArgoCD GitOps | 9개 App Synced & Healthy |
| Grafana Monitoring | Dashboard 정상 표시 |
| Loki Log Aggregation | 로그 쿼리 정상 |
| Kiali Service Mesh | Traffic Graph/Workloads 정상 |
| Istio mTLS | STRICT 모드 적용 |
| NetworkPolicy | Zero Trust 모델 동작 |
| External Secrets | GCP Secret Manager 동기화 |
| Cluster Resource | CPU 10.8%, Memory 30.3% |

## 관련 문서

- [Demo Screenshots](../demo/README.md)
- [Architecture](../architecture/README.md)
- [Performance](../06-performance/README.md)
