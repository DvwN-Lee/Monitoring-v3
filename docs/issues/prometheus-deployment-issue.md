# Issue: Prometheus Server 배포 실패

## 상태
- Priority: High
- Status: Open
- Created: 2026-01-24

## 개요
kube-prometheus-stack Application에 Server-Side Apply 옵션 추가 후에도 Prometheus Server Pod가 생성되지 않음.

## 증상
- Prometheus CR이 생성되었으나 StatefulSet이 생성되지 않음
- ArgoCD Application 상태: OutOfSync, Progressing
- Prometheus CR 상태: DESIRED=1, READY=<empty>

## 환경
- Cluster: titanium-k3s-20260123
- Namespace: monitoring
- Chart: kube-prometheus-stack 79.5.0

## 분석

### 현재 상태
```bash
$ kubectl get prometheus -n monitoring
NAME                                    VERSION   DESIRED   READY   RECONCILED   AVAILABLE   AGE
prometheus-kube-prometheus-prometheus   v3.7.3    1                                          119s
```

### 수정 내역
ArgoCD Application Manifest에 Server-Side Apply 옵션 추가:
```yaml
spec:
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true  # 추가됨
```

### Prometheus Operator 로그
TLS handshake error 다수 발생:
```
level=error msg="http: TLS handshake error from 10.42.0.1:xxxxx: remote error: tls: bad certificate"
```

## 근본 원인 (추정)
1. CRD annotation 크기 제한 초과 문제는 Server-Side Apply로 우회됨
2. Prometheus Operator와 Kubernetes API Server 간 TLS 인증 문제 가능성
3. Prometheus StatefulSet 생성을 위한 RBAC 권한 부족 가능성

## 해결 방안

### 단기 (임시 조치)
1. Prometheus Operator 재시작:
```bash
kubectl rollout restart deployment prometheus-kube-prometheus-operator -n monitoring
```

2. Prometheus CR 삭제 후 재생성:
```bash
kubectl delete prometheus prometheus-kube-prometheus-prometheus -n monitoring
kubectl annotate application kube-prometheus-stack -n argocd argocd.argoproj.io/refresh=normal --overwrite
```

### 중기 (근본 해결)
1. Prometheus Operator RBAC 권한 확인 및 수정
2. TLS Certificate 검증 및 갱신
3. kube-prometheus-stack Chart 버전 업그레이드 고려

### 장기 (Architecture 개선)
1. Prometheus CR을 직접 관리하는 대신 Helm Values로 관리
2. Prometheus Operator를 별도 Namespace로 분리
3. Custom Resource 최소화 및 Native Kubernetes Resource 활용

## 관련 파일
- `apps/infrastructure/kube-prometheus-stack.yaml`
- ArgoCD Application: `kube-prometheus-stack`

## 다음 단계
1. Prometheus Operator 로그 상세 분석
2. RBAC 권한 확인
3. StatefulSet 생성 실패 원인 파악
4. 필요시 Chart Version Downgrade 테스트

## 참고 링크
- kube-prometheus-stack Chart: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- Server-Side Apply: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/#server-side-apply
