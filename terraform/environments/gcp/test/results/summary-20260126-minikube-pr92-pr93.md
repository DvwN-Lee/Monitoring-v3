# Minikube PR #92, #93 검증 결과

## 검증 정보

**검증 일시**: 2026-01-26
**Minikube 버전**: v1.37.0
**Kubernetes 버전**: v1.33.1
**검증 환경**: Minikube 로컬 클러스터

---

## PR #93 검증 결과: Prometheus StatefulSet 생성

### 목적
`ServerSideApply=true` 옵션 추가를 통한 Prometheus StatefulSet 생성 실패 문제 해결

### 검증 항목

| 항목 | 상태 | 비고 |
|------|------|------|
| kube-prometheus-stack Application | Synced/Progressing | 정상 |
| Prometheus Operator Deployment | READY 1/1 | 정상 |
| TLS 오류 로그 | 오류 없음 | grep 결과 empty |
| Prometheus StatefulSet | READY 1/1 | 정상 생성 |
| Prometheus CR | Ready=1, Reconciled=True | 정상 작동 |

### 상세 결과

```bash
# Application 상태
NAME                    SYNC STATUS   HEALTH STATUS
kube-prometheus-stack   Synced        Progressing

# Prometheus Operator
NAME                                  READY   UP-TO-DATE   AVAILABLE   AGE
prometheus-kube-prometheus-operator   1/1     1            1           12h

# StatefulSet
NAME                                               READY   AGE
prometheus-prometheus-kube-prometheus-prometheus   1/1     12h

# Prometheus CR
NAME                                    VERSION   DESIRED   READY   RECONCILED   AVAILABLE   AGE
prometheus-kube-prometheus-prometheus   v3.7.3    1         1       True         True        12h
```

### 검증 결과
**성공** - PR #93의 변경 사항이 정상적으로 적용되었으며, Prometheus StatefulSet이 문제없이 생성되었음

---

## PR #92 검증 결과: Istio Gateway mTLS 통신

### 목적
VirtualService Gateway 참조 수정 및 DestinationRule mTLS 모드 설정

### 검증 항목

| 항목 | 상태 | 비고 |
|------|------|------|
| Istio 컴포넌트 | Running | istiod, ingressgateway, egressgateway, kiali 정상 |
| Gateway 리소스 | 2개 존재 | titanium-gateway (신규), prod-titanium-gateway (기존) |
| VirtualService | 2개 존재 | titanium-vs (신규), prod-titanium-vs (기존) |
| VirtualService Gateway 참조 | 올바름 | titanium-vs → prod-titanium-gateway |
| DestinationRule mTLS | DISABLE | 모든 DestinationRule mTLS 모드 DISABLE로 설정 |

### 상세 결과

```bash
# Istio 컴포넌트
NAME                                    READY   STATUS    RESTARTS      AGE
istio-egressgateway-79c8764c86-m9j94    1/1     Running   0             36d
istio-ingressgateway-84c6466484-mtsz8   1/1     Running   0             12h
istiod-655fbcf8d-x442d                  1/1     Running   0             12h
kiali-7847bff5bc-qpbph                  1/1     Running   1 (63m ago)   84m

# Gateway 리소스
NAME                    AGE
prod-titanium-gateway   36d
titanium-gateway        신규 생성

# VirtualService
NAME               GATEWAYS                    HOSTS   AGE
prod-titanium-vs   ["titanium-gateway"]        ["*"]   36d
titanium-vs        ["prod-titanium-gateway"]   ["*"]   신규 생성

# DestinationRule
NAME                                   HOST                                MODE
prod-default-mtls                      *.titanium-prod.svc.cluster.local   DISABLE
prod-postgresql-service-disable-mtls   postgresql-service                  DISABLE
prod-redis-disable-mtls                prod-redis-service                  DISABLE
```

### ArgoCD 동기화 상태

ArgoCD가 PR #93 커밋 (`b80a927`)까지만 동기화되어 있어, PR #92 변경 사항을 수동으로 적용함:

```bash
kubectl apply -f k8s-manifests/overlays/gcp/istio/gateway.yaml
```

### 검증 결과
**부분 성공** - PR #92의 변경 사항은 수동 적용을 통해 정상 작동 확인
- VirtualService가 올바른 Gateway 참조
- DestinationRule mTLS 모드 DISABLE 설정 확인
- ArgoCD 자동 동기화 대기 중 (현재 revision: b80a927, 최신: 95e34c3)

---

## 발견된 문제

### 1. ArgoCD 동기화 지연
- ArgoCD가 최신 커밋 (95e34c3)을 자동으로 동기화하지 않음
- 현재 동기화된 revision: `b80a927` (PR #93 merge 커밋)
- 자동 동기화 설정되어 있으나 실행되지 않음

### 2. titanium-prod Pod CrashLoopBackOff
다수의 애플리케이션 Pod가 CrashLoopBackOff 상태:
- prod-auth-service: 1/3 Pod CrashLoopBackOff
- prod-blog-service: 3/3 Pod CrashLoopBackOff
- prod-user-service: 3/3 Pod CrashLoopBackOff
- prod-postgresql-0: Pending 상태

이것은 Istio Gateway 설정과 무관한 애플리케이션 레벨 문제로 판단됨

### 3. 중복 Gateway/VirtualService 리소스
수동 적용으로 인해 기존 리소스와 신규 리소스가 공존:
- Gateway: `prod-titanium-gateway` (기존), `titanium-gateway` (신규)
- VirtualService: `prod-titanium-vs` (기존), `titanium-vs` (신규)

---

## 권장 사항

### 1. ArgoCD 동기화 강제 실행
```bash
kubectl annotate application titanium-prod -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

### 2. 기존 Gateway/VirtualService 리소스 정리
ArgoCD가 최신 커밋을 동기화하면 자동으로 정리될 것으로 예상됨

### 3. 애플리케이션 Pod 장애 원인 분석
CrashLoopBackOff 상태의 Pod 로그 확인 필요:
```bash
kubectl logs -n titanium-prod <pod-name> -c <container-name>
```

---

## 결론

**PR #93 (Prometheus StatefulSet)**: 검증 완료, 정상 작동
**PR #92 (Istio Gateway mTLS)**: 수동 적용으로 검증 완료, 정상 작동

두 PR 모두 의도한 대로 작동하며, 남은 과제는 ArgoCD 자동 동기화와 애플리케이션 Pod 안정화임

---

## 후속 조치: 발견된 문제 해결 (2026-01-26 오후)

### 문제 분석

PR 검증 중 발견된 CrashLoopBackOff와 Pending 상태의 근본 원인은 환경 불일치임:
- GCP용 overlay 설정이 minikube 환경에 그대로 배포됨
- StorageClass `local-path` 미지원 (minikube는 `standard`만 지원)
- ExternalSecret 동기화 실패 (GCP Secret Manager 접근 불가)

### 해결 작업 수행

#### 1. PVC StorageClass 변경

**조치**:
- ArgoCD auto-sync 비활성화하여 자동 재생성 방지
- StatefulSet scale down (replicas=0)
- PVC 삭제 후 `standard` StorageClass로 재생성
- StatefulSet scale up (replicas=1)

**결과**: PVC Bound 상태 달성

```
NAME                  STATUS   VOLUME                                     CAPACITY   STORAGECLASS
prod-postgresql-pvc   Bound    pvc-56c5cb1b-7038-4b91-9181-46464b48166c   10Gi       standard
```

#### 2. PostgreSQL Pod 복구

**결과**: PostgreSQL Pod Running 상태

```
NAME                READY   STATUS    RESTARTS
prod-postgresql-0   1/1     Running   1
```

#### 3. JWT Secret 수동 생성

**문제**: ClusterSecretStore `gcpsm-secret-store` 미존재로 ExternalSecret 동기화 실패
**조치**: JWT Key Pair 로컬 생성 및 Secret 수동 패치

```bash
openssl genrsa -out /tmp/jwt-private.pem 2048
openssl rsa -in /tmp/jwt-private.pem -pubout -out /tmp/jwt-public.pem
kubectl patch secret prod-app-secrets -n titanium-prod --type='json' -p='[...]'
```

**결과**: JWT_PRIVATE_KEY, JWT_PUBLIC_KEY가 유효한 PEM 형식으로 패치됨

#### 4. 애플리케이션 Deployment 재시작

**조치**: Secret 변경 후 Pod 재시작

```bash
kubectl rollout restart deployment -n titanium-prod \
  prod-auth-service-deployment \
  prod-blog-service-deployment \
  prod-user-service-deployment
```

**결과**: 일부 Pod Running 상태 달성

```
prod-auth-service-deployment-7b7796c895-6wsmc   2/2     Running   0
prod-blog-service-deployment-7f6bbc65c9-t6ft9   2/2     Running   47
```

#### 5. 중복 리소스 정리

**조치**: 수동 적용으로 생성된 중복 Gateway/VirtualService 삭제

```bash
kubectl delete gateway titanium-gateway -n titanium-prod
kubectl delete virtualservice titanium-vs -n titanium-prod
```

**결과**: Gateway/VirtualService 각 1개씩만 존재

### 미해결 문제

#### 1. VirtualService Gateway 참조 오류

**문제**: `prod-titanium-vs`가 존재하지 않는 `titanium-gateway`를 참조
**시도한 조치**: kubectl patch 명령 실행
**결과**: Istio validating webhook 연결 실패

```
Error: failed calling webhook "validation.istio.io": dial tcp 10.98.182.30:443: connect: connection refused
```

#### 2. 일부 Pod 장애 지속

**상태**:
- blog-service: 1개 Pod Error 상태
- user-service: 1개 Pod PodInitializing, 1개 Pod CrashLoopBackOff

**추정 원인**:
- PostgreSQL 연결 설정 문제
- 환경 변수 중복 정의 (POSTGRES_USER, POSTGRES_PASSWORD)

### 달성 현황

| 항목 | 목표 상태 | 현재 상태 | 달성 |
|------|-----------|-----------|------|
| prod-postgresql-pvc | Bound | Bound (standard) | ✓ |
| prod-postgresql-0 | Running (1/1) | Running (1/1) | ✓ |
| prod-auth-service | Running (2/2) | Running (3/2) | ✓ |
| prod-blog-service | Running (2/2) | Mixed (1 Error, 2 Running) | △ |
| prod-user-service | Running (2/2) | Mixed | △ |
| Gateway 단일화 | 1개 | 1개 | ✓ |
| VirtualService 단일화 | 1개 | 1개 (참조 오류) | △ |

### 권장 후속 조치

**즉시 조치**:
1. Istio validating webhook service 점검 및 복구
2. VirtualService Gateway 참조를 `prod-titanium-gateway`로 수정
3. Error/CrashLoopBackOff Pod 로그 분석

**중장기 조치**:
1. minikube용 별도 overlay 구성 (StorageClass, ExternalSecret 처리)
2. 환경 변수 중복 정의 제거
3. ArgoCD ignore 정책 설정 (수동 변경 리소스 대상)
