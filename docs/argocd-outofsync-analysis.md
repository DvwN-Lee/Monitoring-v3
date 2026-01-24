# ArgoCD OutOfSync 상태 분석 보고서

ArgoCD Application의 OutOfSync 상태에 대한 원인 분석 및 권장 조치 사항을 정리한 문서입니다.

## 현재 상태 요약

| Application | Sync Status | Health Status | 비고 |
|-------------|-------------|---------------|------|
| istio-base | OutOfSync | Healthy | ValidatingWebhookConfiguration |
| istiod | OutOfSync | Healthy | Deployment, ValidatingWebhookConfiguration |
| titanium-prod | OutOfSync | Healthy | PodMonitor |
| istio-ingressgateway | Synced | Healthy | 정상 |
| kiali | Synced | Healthy | 정상 |
| kube-prometheus-stack | Synced | Healthy | 정상 |
| loki-stack | Synced | Healthy | 정상 |

---

## OutOfSync 원인 분석

### 1. istio-base

**OutOfSync Resource:**
- `ValidatingWebhookConfiguration/istiod-default-validator`

**원인:**
- Istio Helm chart로 배포됨 (source: `https://istio-release.storage.googleapis.com/charts`)
- `caBundle` 필드가 Istio CA에 의해 runtime에 동적으로 주입됨
- Helm chart template에는 caBundle이 빈 값 또는 placeholder로 정의되어 있음
- ArgoCD는 Git(Helm chart) 상태와 Cluster 상태의 차이로 인식

### 2. istiod

**OutOfSync Resources:**
- `Deployment/istiod`
- `ValidatingWebhookConfiguration/istio-validator-istio-system`

**원인:**
- Helm chart 기반 배포 (version: 1.24.2)
- Deployment: Kubernetes가 적용하는 기본값 필드들 (status, metadata annotations 등)
- ValidatingWebhookConfiguration: istio-base와 동일한 caBundle 동적 주입 이슈

### 3. titanium-prod

**OutOfSync Resource:**
- `PodMonitor/prod-envoy-stats-monitor`

**원인:**
- Kustomize `namePrefix: prod-` 적용됨
- Git source: `envoy-stats-monitor` -> Cluster: `prod-envoy-stats-monitor`
- ServerSideApply 또는 YAML array 표현 방식 정규화 차이
- `relabelings` 필드의 문법적 차이 (한 줄 vs 여러 줄)

---

## 결론

**OutOfSync 상태는 운영상 문제가 아닙니다.**

1. 모든 Application이 **Healthy** 상태
2. 실제 workload는 정상 동작 중
3. OutOfSync 원인 요약:
   - Helm chart의 동적 필드 (caBundle)
   - Kubernetes의 기본값 주입
   - YAML 정규화 차이

---

## 권장 조치

### Option A: 현재 상태 유지 (채택)

**근거:**
- 모든 Application이 Healthy 상태
- OutOfSync는 cosmetic issue (시각적 표시 차이)
- Istio의 caBundle 동적 주입은 정상적인 보안 메커니즘
- ignoreDifferences 설정은 추후 관리 복잡성 증가

**적용 사항:**
- 추가 작업 불필요
- Monitoring은 Health 상태 기준으로 수행
- Sync Status가 아닌 Health Status를 운영 기준으로 사용

### Option B: ignoreDifferences 설정 추가 (미적용)

참고용으로 ignoreDifferences 설정 방법을 기록합니다.

**적용 대상:**
- istio-base, istiod: `caBundle` 필드 ignore
- titanium-prod: PodMonitor relabelings ignore

**설정 예시:**
```yaml
spec:
  ignoreDifferences:
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      jsonPointers:
        - /webhooks/0/clientConfig/caBundle
        - /webhooks/1/clientConfig/caBundle
```

**적용 방법:**
- ArgoCD Application CRD 직접 수정 (`kubectl edit`)
- 또는 ArgoCD Application manifest 파일에 추가 후 재배포

---

## 검증 방법

### ArgoCD Application 상태 확인

```bash
# 전체 Application 상태 조회
argocd app list

# 특정 Application 상세 정보
argocd app get <app-name>

# Health 상태만 필터링
kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.health.status}{"\n"}{end}'
```

### OutOfSync 상세 원인 조회

```bash
# ArgoCD UI에서 확인
# 또는 CLI로 diff 조회
argocd app diff <app-name>
```

---

## 운영 가이드라인

### Monitoring 기준

| 항목 | 기준 | Alert 필요 |
|------|------|-----------|
| Health Status | Healthy 외 상태 | O |
| Sync Status | OutOfSync | X (분석된 원인에 해당하는 경우) |
| Degraded | 발생 시 | O |
| Missing | 발생 시 | O |

### 정기 점검 사항

1. 모든 Application의 Health Status가 `Healthy`인지 확인
2. OutOfSync Application의 원인이 문서화된 내용과 일치하는지 확인
3. 새로운 OutOfSync 발생 시 원인 분석 후 문서 업데이트

---

## 참고 자료

- [ArgoCD Sync Status Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- [Istio Helm Installation Guide](https://istio.io/latest/docs/setup/install/helm/)
- [ArgoCD ignoreDifferences Configuration](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)

---

**분석 일자:** 2026-01-23
**분석 환경:** titanium-prod Cluster (GKE)
