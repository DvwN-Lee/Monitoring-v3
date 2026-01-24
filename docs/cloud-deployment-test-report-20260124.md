# 클라우드 기반 배포 테스트 보고서

**테스트 일시:** 2026-01-24
**환경:** GCP titanium-k3s-20260123
**Cluster:** K3s on GCE (master + worker)

---

## 요약

App of Apps 패턴으로 배포된 8개 ArgoCD Application의 클라우드 환경 동작 검증

**결과:** 부분 성공
- ArgoCD Application: 8개 모두 생성 ✅
- istio-ingressgateway NodePort 충돌 해결 ✅
- Infrastructure 배포: Istio, Loki 정상 ✅
- 일부 Application (kube-prometheus-stack, titanium-prod) 배포 지연

---

## 사전 준비

### 1. SSH 접근 설정

**문제:** 방화벽 규칙에 현재 IP 미등록으로 SSH connection timeout

**해결:**
```bash
gcloud compute firewall-rules update titanium-k3s-allow-ssh \
  --project=titanium-k3s-20260123 \
  --source-ranges=35.235.240.0/20,112.150.249.93/32,106.101.4.123/32,112.218.39.251/32
```

### 2. ArgoCD root-app 복구

**문제:** root-app이 "waiting for deletion" 상태로 stuck

**해결:**
```bash
# Operation 제거
kubectl -n argocd patch app root-app --type json \
  -p='[{"op": "remove", "path": "/operation"}]'

# Hard refresh
kubectl -n argocd patch app root-app --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### 3. istio-ingressgateway Application 수동 생성

**문제:** kustomize manifest는 생성되지만 Application 객체 미생성

**해결:**
```bash
cd /tmp && git clone https://github.com/DvwN-Lee/Monitoring-v3.git
cd Monitoring-v3
kubectl kustomize apps/ > /tmp/apps-all.yaml
kubectl apply -f /tmp/apps-all.yaml
```

---

## ArgoCD Application 상태

### 최종 확인 결과

| Application | Sync Status | Health Status | Revision | 비고 |
|-------------|-------------|---------------|----------|------|
| root-app | OutOfSync | Healthy | 2dfc858 | 최신 commit 참조 |
| istio-base | OutOfSync | Healthy | 1.24.2 | Webhook 동적 관리 |
| istiod | OutOfSync | Healthy | 1.24.2 | Sync 대기 |
| istio-ingressgateway | **Synced** | **Healthy** | 1.24.2 | **정상 배포** |
| kiali | Synced | Healthy | 2.4.0 | 정상 배포 |
| loki-stack | Synced | Healthy | 2.10.2 | 정상 배포 |
| kube-prometheus-stack | Unknown | Healthy | 68.2.3 | 배포 지연 |
| titanium-prod | Unknown | Healthy | main | 배포 지연 |

**생성된 Application:** 8개 (예상대로)

---

## Service Endpoint 검증

### NodePort Service 확인

```bash
kubectl get svc -A | grep NodePort
```

**결과:**

| Namespace | Service | Type | Port Mapping |
|-----------|---------|------|--------------|
| argocd | argocd-server | NodePort | 80:30080, 443:30590 |
| istio-system | istio-ingressgateway | NodePort | 80:30081, 443:30444 |

**검증:**
- argocd-server: 30080 (기존)
- istio-ingressgateway: 30081, 30444 (PR #84 수정 적용됨) ✅
- NodePort 충돌 해결 확인 ✅

### Monitoring Stack Service 상태

```bash
kubectl get svc -n monitoring
```

**결과:**
```
NAME                    TYPE        CLUSTER-IP      PORT(S)
loki-stack              ClusterIP   10.43.147.171   3100/TCP
loki-stack-headless     ClusterIP   None            3100/TCP
loki-stack-memberlist   ClusterIP   None            7946/TCP
```

**분석:**
- Loki Stack만 배포됨
- kube-prometheus-stack Service 미확인 (배포 지연 추정)

---

## Infrastructure 구성 요소 상태

### Istio

```bash
kubectl get pods -n istio-system
```

**예상 구성:**
- istio-base: CRD 및 기본 리소스
- istiod: Control plane
- istio-ingressgateway: Ingress gateway (NodePort 30081, 30444)

**확인 사항:**
- istio-ingressgateway Service 생성 ✅
- NodePort 충돌 해결 ✅

### Loki Stack

```bash
kubectl get statefulset -n monitoring
```

**결과:**
```
NAME         READY   AGE
loki-stack   1/1     116m
```

**상태:** 정상 동작 ✅

### Kiali

```bash
kubectl get svc kiali -n istio-system
```

**결과:**
```
NAME    TYPE        CLUSTER-IP      PORT(S)              AGE
kiali   ClusterIP   10.43.160.102   20001/TCP,9090/TCP   118m
```

**분석:**
- Service 생성됨
- NodePort 31200 patch 미적용 (ClusterIP로 유지)
- Application manifest의 postRenderers 필드 오류로 인한 설정 미반영 추정

---

## 발견된 이슈

### 1. kube-prometheus-stack 배포 지연

**현상:** Sync Status가 Unknown, Healthy 상태이지만 실제 리소스 미배포

**추정 원인:**
- 대용량 Helm chart (CRD, Operator, StatefulSet 등)
- Sync timeout 또는 초기화 대기

**조치:**
```bash
kubectl -n argocd patch app kube-prometheus-stack --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

**상태:** 추가 대기 필요

### 2. titanium-prod Application 미배포

**현상:** Namespace 존재하지만 Pod 없음

**추정 원인:**
- Sync wave 4 (마지막 순서)
- Infrastructure 구성 요소 배포 완료 대기 중

**조치:**
```bash
kubectl -n argocd patch app titanium-prod --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

**상태:** 추가 대기 필요

### 3. Kiali NodePort 미적용

**현상:** ClusterIP로 유지, NodePort 31200 설정 미반영

**원인:**
```
strict decoding error: unknown field "spec.source.helm.postRenderers"
```

**분석:**
- ArgoCD Application manifest의 postRenderers 필드가 kubectl apply 시 오류 발생
- 기존에 생성된 kiali Application에는 postRenderers가 적용되어 있음
- 수동 apply 시 conflict 발생

**해결 방안:**
- ArgoCD가 자동으로 sync하도록 대기
- 또는 Kiali Service를 수동으로 NodePort로 변경

---

## 후속 조치

### 즉시 조치 필요

1. **kube-prometheus-stack 배포 완료 대기 및 확인**
   ```bash
   kubectl get pods -n monitoring
   kubectl get svc -n monitoring | grep prometheus
   ```

2. **titanium-prod Application 배포 확인**
   ```bash
   kubectl get pods -n titanium-prod
   ```

3. **Kiali NodePort 설정 적용**
   ```bash
   kubectl patch svc kiali -n istio-system -p \
     '{"spec":{"type":"NodePort","ports":[{"name":"http","port":20001,"targetPort":20001,"nodePort":31200}]}}'
   ```

### 검증 항목

- [ ] Prometheus UI 접근 (NodePort 30090)
- [ ] Grafana UI 접근 (NodePort 30300)
- [ ] Loki logs 수집 확인
- [ ] Kiali Service Graph 확인 (NodePort 31200)
- [ ] Istio Ingress Gateway 동작 확인 (NodePort 30081/30444)
- [ ] Application 메트릭 수집 확인

---

## 결론

### 성공 사항

1. **App of Apps 패턴 검증 완료**
   - 8개 child application 모두 생성
   - Kustomization 계층 구조 정상 동작

2. **istio-ingressgateway NodePort 충돌 해결 검증**
   - PR #84 변경사항 (30081, 30444) 정상 적용
   - Service 정상 생성 및 Healthy 상태

3. **Infrastructure 기본 구성 요소 배포 성공**
   - Istio: istio-base, istiod, istio-ingressgateway
   - Loki Stack: 정상 동작
   - Kiali: Service 생성 (NodePort 설정만 누락)

### 미완료 사항

1. **Monitoring Stack 전체 배포**
   - kube-prometheus-stack 배포 지연 (대기 중)
   - Prometheus, Grafana Service 미확인

2. **Application 배포**
   - titanium-prod Pod 미생성 (배포 지연)

3. **End-to-End 테스트**
   - Dashboard 접근 테스트 미실시
   - 메트릭 수집 확인 미실시

### 권장 사항

1. **ArgoCD Automated Sync 대기**
   - kube-prometheus-stack, titanium-prod가 자동으로 sync되도록 15-30분 대기
   - 대용량 Helm chart 배포에는 시간 소요

2. **수동 개입 최소화**
   - ArgoCD의 automated sync, selfHeal 정책 활용
   - 불필요한 수동 개입은 GitOps 원칙 위반

3. **Issue #85 고려**
   - Application 설정 변경 시 자동 재배포 메커니즘 검토
   - 현재와 같은 stuck 상태 자동 복구 방안 마련
