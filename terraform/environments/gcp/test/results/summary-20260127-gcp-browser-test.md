# IaC 기반 모니터링 Service 외부 접근 문제 해결 및 Browser Testing 결과

날짜: 2026-01-27
환경: GKE (staging-exam-cluster)

## 문제 분석

ArgoCD Application의 Helm values에 하드코딩된 NodePort 값이 Terraform variables와 불일치하여 외부 접근 문제가 발생했습니다.

| Service | 기존 NodePort | 수정된 NodePort | Terraform Variable |
|---------|---------------|-----------------|-------------------|
| Prometheus | 30090 | 31090 | var.prometheus_nodeport |
| Grafana | 30300 | 31300 | var.grafana_nodeport |
| Kiali | ClusterIP (postRenderers 사용) | 31200 | var.kiali_nodeport |

## 해결 방법

### 1. kube-prometheus-stack NodePort 수정

파일: `apps/infrastructure/kube-prometheus-stack.yaml`

```yaml
prometheus:
  service:
    type: NodePort
    nodePort: 31090  # 30090 -> 31090

grafana:
  service:
    type: NodePort
    nodePort: 31300  # 30300 -> 31300
```

### 2. Kiali NodePort 설정 변경

파일: `apps/infrastructure/kiali.yaml`

ArgoCD는 `postRenderers`를 지원하지 않으므로, Helm values에서 직접 NodePort를 설정했습니다.

```yaml
helm:
  values: |
    deployment:
      namespace: istio-system
      service_type: NodePort
    server:
      node_port: 31200
```

기존 `postRenderers` 블록 제거:

```yaml
# 제거된 블록
postRenderers:
  - kustomize:
      patches:
        - target:
            kind: Service
            name: kiali
          patch: |-
            - op: replace
              path: /spec/type
              value: NodePort
            - op: add
              path: /spec/ports/0/nodePort
              value: 31200
```

### 3. Git Commit & ArgoCD Sync

```bash
git add apps/infrastructure/kube-prometheus-stack.yaml apps/infrastructure/kiali.yaml
git commit -m "fix(argocd): monitoring service NodePort를 Terraform variables와 일치하도록 수정"
git push origin main

# ArgoCD sync 트리거
kubectl patch application kube-prometheus-stack -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
kubectl patch application kiali -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

## Service 상태 검증 결과

### monitoring namespace

```
NAME                                    TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)                         AGE
prometheus-grafana                      NodePort    10.101.13.224   <none>        80:31300/TCP                    25m
prometheus-kube-prometheus-prometheus   NodePort    10.101.11.148   <none>        9090:31090/TCP,8080:31299/TCP   25m
```

### istio-system namespace

```
NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)                                 AGE
kiali                  NodePort    10.101.13.126   <none>        20001:31200/TCP,9090:30829/TCP          26m
```

모든 Service가 올바른 NodePort로 설정되었습니다.

## Browser Testing 결과

### GKE 환경 (port-forward 방식)

GKE Node는 기본적으로 External IP를 할당받지 않으므로, `kubectl port-forward`를 통해 로컬에서 검증했습니다.

#### Prometheus (http://localhost:31090/targets)

- 접근: 정상
- 상태: 모든 Envoy sidecar metrics UP
  - user-service (10.100.1.72:15090)
  - api-gateway (10.100.0.22:15090)
  - auth-service (10.100.2.82:15090)
  - blog-service (10.100.1.71:15090)
- Target 개수: 9/9 UP

#### Grafana (http://localhost:31300)

- 접근: 정상
- 로그인: admin / admin (skip password update)
- Dashboard: Welcome to Grafana 페이지 정상 표시
- Data Sources:
  - Loki: 정상 연결 (http://loki-stack:3100)
  - Prometheus: 자동 설정 없음 (Helm values에서 별도 설정 필요)

#### Kiali (http://localhost:31200/kiali)

- 접근: 정상
- 인증: Token 기반 로그인 화면 표시
- Status: Kiali Service 정상 동작

### k3s 환경

현재 kubectl context가 GKE를 가리키고 있으며, k3s 인스턴스(34.64.171.141)는 존재하지만 별도로 모니터링 스택 배포 상태 미확인.

k3s 환경 NodePort 직접 접근을 위해서는:
1. k3s kubeconfig 설정
2. 모니터링 스택 배포 확인
3. 방화벽 규칙 설정 (31090, 31300, 31200 포트)

## 검증 항목 체크리스트

| 항목 | GKE 환경 | k3s 환경 |
|------|----------|----------|
| Prometheus Targets 접근 | ✓ | - |
| Envoy sidecar metrics UP | ✓ (9/9) | - |
| Grafana 로그인 | ✓ | - |
| Grafana Dashboard 표시 | ✓ | - |
| Loki Datasource 연결 | ✓ | - |
| Kiali Service 접근 | ✓ | - |

## 결론

ArgoCD Application Helm values를 Terraform variables와 동기화하여 NodePort 불일치 문제를 해결했습니다. GKE 환경에서 모든 모니터링 서비스가 정상적으로 동작하며, port-forward를 통한 접근 검증이 완료되었습니다.

### 향후 작업

1. GKE 환경에서 외부 접근이 필요한 경우:
   - Load Balancer Type Service 사용
   - Ingress 설정 (TLS 인증서 포함)

2. k3s 환경 검증:
   - k3s kubeconfig 설정
   - 방화벽 규칙 추가
   - NodePort 직접 접근 테스트

3. Grafana Prometheus Datasource 자동 설정:
   - `kube-prometheus-stack` Helm values에 추가

## 변경 파일

- `apps/infrastructure/kube-prometheus-stack.yaml`
- `apps/infrastructure/kiali.yaml`

Commit: fix(argocd): monitoring service NodePort를 Terraform variables와 일치하도록 수정 (1c0bccf)
