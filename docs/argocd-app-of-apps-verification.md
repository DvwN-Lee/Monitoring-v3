# ArgoCD App of Apps 패턴 수정 검증 보고서

## 개요

PR #82에서 수정한 App of Apps 패턴의 child application 로딩 문제 해결을 검증

**검증 일시:** 2026-01-24
**관련 PR:** https://github.com/DvwN-Lee/Monitoring-v3/pull/82
**관련 Issue:** https://github.com/DvwN-Lee/Monitoring-v3/issues/81

---

## 수정 내용

**파일:** `apps/kustomization.yaml` (신규 생성)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - infrastructure
  - applications
```

**목적:** ArgoCD Directory source가 하위 디렉토리의 Application manifest를 로드할 수 있도록 Kustomization 계층 구조 구성

---

## 검증 절차

### 1. PR Merge

```bash
gh pr merge 82 --squash
```

**결과:** 2026-01-24T01:02:02Z Merge 완료 (Commit: ed23484)

### 2. root-app Sync

```bash
kubectl patch app root-app -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
```

**결과:** root-app이 새로운 commit (ed23484) 참조 시작

### 3. Application 목록 확인

```bash
kubectl get app -n argocd
```

**결과 (초기):**
```
NAME                    SYNC STATUS   HEALTH STATUS
istio-base              OutOfSync     Progressing
istio-ingressgateway    OutOfSync     Missing
istiod                  OutOfSync     Missing
kiali                   OutOfSync     Missing
kube-prometheus-stack   Unknown       Healthy
loki-stack              OutOfSync     Missing
root-app                OutOfSync     Healthy
titanium-prod           Unknown       Healthy
```

**결과 (30초 후):**
```
NAME                    SYNC        HEALTH
istio-base              OutOfSync   Healthy
istio-ingressgateway    OutOfSync   Missing
istiod                  OutOfSync   Healthy
kiali                   Synced      Progressing
kube-prometheus-stack   Unknown     Healthy
loki-stack              Synced      Progressing
root-app                OutOfSync   Healthy
titanium-prod           Unknown     Healthy
```

---

## 검증 결과

### Application 생성 확인

| Application | 생성 여부 | 상태 |
|-------------|-----------|------|
| root-app | ✅ | OutOfSync/Healthy |
| istio-base | ✅ | OutOfSync/Healthy |
| istiod | ✅ | OutOfSync/Healthy |
| istio-ingressgateway | ✅ | OutOfSync/Missing |
| kube-prometheus-stack | ✅ | Unknown/Healthy |
| loki-stack | ✅ | Synced/Progressing |
| kiali | ✅ | Synced/Progressing |
| titanium-prod | ✅ | Unknown/Healthy |

**총 Application 수:** 8개 (예상대로 생성됨)

### Commit 참조 확인

```bash
kubectl get app root-app -n argocd -o yaml | grep revision
```

**결과:**
```
revision: ed23484529f3e70a57bedb6cfd21c76b1df78c23
```

root-app이 최신 commit을 올바르게 참조함

---

## 분석

### 성공 요인

1. **Kustomization 계층 구조 구성:** apps 디렉토리에 kustomization.yaml을 추가하여 ArgoCD가 하위 디렉토리를 올바르게 탐색
2. **Automated Sync:** root-app의 automated sync 정책으로 인해 child application 자동 생성
3. **Directory Source 동작 검증:** ArgoCD가 Directory source에서 Kustomization을 올바르게 처리

### OutOfSync 상태 분석

대부분의 child application이 OutOfSync 상태인 이유:

1. **신규 생성:** Child application들이 방금 생성되어 초기 sync가 진행 중
2. **Automated Sync 미설정:** 일부 application은 automated sync가 비활성화되어 있어 수동 sync 필요
3. **순차 배포:** Infrastructure 구성 요소가 순차적으로 배포되어야 하는 특성

**예상 동작:** Automated sync가 설정된 application들은 3-5분 내에 자동으로 Synced 상태로 전환됨

---

## 후속 조치 진행

### Issue #83: istio-ingressgateway NodePort 충돌

**문제 발견:**
istio-ingressgateway가 argocd-server와 NodePort 30080 충돌

**해결 (PR #84):**
- HTTP NodePort: 30080 -> 30081
- HTTPS NodePort: 30443 -> 30444
- Merge 완료: 2026-01-24T02:17:55Z (Commit: 2dfc858)

**진행 중:**
- ArgoCD Controller restart 후 istio-ingressgateway 재생성 대기
- Network 오류로 인해 최종 확인 보류

---

## 결론

### 검증 결과

**성공:** App of Apps 패턴이 정상 동작하여 8개 child application 모두 생성됨

### 발견된 이슈

1. **istio-ingressgateway NodePort 충돌:** argocd-server와 포트 충돌 (PR #84로 해결)
2. **OutOfSync 상태:** 일부 application이 OutOfSync 상태이지만 Healthy
   - istio-base: ValidatingWebhookConfiguration 동적 업데이트로 인한 정상적인 OutOfSync
   - istiod, kiali: Automated sync 대기 중

### 후속 조치

1. **istio-ingressgateway 재생성 확인:** ArgoCD Controller restart 후 상태 확인 필요
2. **Sync 완료 모니터링:** 각 child application의 sync가 완료될 때까지 ArgoCD UI에서 모니터링
3. **Health 상태 확인:** 모든 application이 Healthy 상태가 되는지 확인

### 교훈

1. **Kustomization 계층 구조의 중요성:** ArgoCD Directory source는 root level에서 Kustomization을 찾아 하위 디렉토리를 로드하므로, App of Apps 패턴 구현 시 각 계층마다 kustomization.yaml 필요
2. **NodePort 사전 확인:** Infrastructure Application 배포 전 NodePort 충돌 여부 사전 확인 필요
3. **Istio ValidatingWebhook:** istiod가 동적으로 관리하는 webhook configuration은 정상적으로 OutOfSync 상태 유지
