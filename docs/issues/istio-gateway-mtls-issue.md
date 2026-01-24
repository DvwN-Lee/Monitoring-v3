# Issue: Istio Gateway mTLS 통신 실패

## 상태
- Priority: Critical
- Status: Open
- Created: 2026-01-24

## 개요
Istio Ingress Gateway에서 Backend Service (prod-blog-service 등)로의 연결이 실패하여 모든 HTTP 요청이 503 에러 발생.

## 증상
```
upstream connect error or disconnect/reset before headers.
retried and the latest reset reason: remote connection failure,
transport failure reason: delayed connect error: Connection refused
```

## 환경
- Cluster: titanium-k3s-20260123
- Gateway: istio-ingressgateway (istio-system namespace)
- Application: titanium-prod namespace
- mTLS Mode: STRICT

## 분석

### 현재 설정

#### PeerAuthentication
```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: prod-default-mtls
  namespace: titanium-prod
spec:
  mtls:
    mode: STRICT
```

#### DestinationRule
```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: prod-default-mtls
  namespace: titanium-prod
spec:
  host: "*.titanium-prod.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

### 확인된 사항
1. **Pod 상태**: 모든 Application Pod Running 정상
2. **Service Endpoints**: 정상 등록됨
   ```
   prod-blog-service: 10.42.0.19:8005, 10.42.1.19:8005
   ```
3. **Gateway 설정**: VirtualService 라우팅 규칙 정상
4. **ServiceAccount**: prod-blog-service-sa 존재 및 Pod에 적용됨
5. **Istio Proxy 설정**: Gateway에서 Backend Service Cluster 설정 정상
   ```
   outbound|8005||prod-blog-service.titanium-prod.svc.cluster.local
   match_subject_alt_names: spiffe://cluster.local/ns/titanium-prod/sa/prod-blog-service-sa
   ```

### 근본 원인
Istio Ingress Gateway (istio-system namespace)에서 Backend Service (titanium-prod namespace)로 연결 시 mTLS 인증 실패.

**확인된 원인**:
1. PeerAuthentication을 PERMISSIVE로 변경했으나 DestinationRule이 여전히 ISTIO_MUTUAL 모드 사용
2. DestinationRule(Client-side)과 PeerAuthentication(Server-side)의 불일치
3. Gateway가 ISTIO_MUTUAL을 사용하려 하지만 적절한 클라이언트 인증서 제공 불가

**기술적 세부사항**:
- PeerAuthentication(Server-side): PERMISSIVE - mTLS 및 Plain text 모두 허용
- DestinationRule(Client-side): ISTIO_MUTUAL - 항상 mTLS 사용 시도
- 결과: Gateway가 mTLS로 연결 시도 → 인증 실패 → Connection refused

## 해결 방안

### 단기 (임시 조치) - PERMISSIVE 모드로 변경

#### 방법 1: Namespace 전체를 PERMISSIVE로 변경
```yaml
# k8s-manifests/overlays/gcp/istio/peer-authentication.yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-mtls
  namespace: titanium-prod
spec:
  mtls:
    mode: PERMISSIVE  # STRICT -> PERMISSIVE 변경
```

#### 방법 2: Ingress Gateway에서 들어오는 트래픽만 PERMISSIVE 허용
```yaml
# k8s-manifests/overlays/gcp/istio/peer-authentication-ingress.yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: ingress-permissive
  namespace: titanium-prod
spec:
  selector:
    matchLabels:
      version: v1  # Application Pod selector
  mtls:
    mode: PERMISSIVE
  portLevelMtls:
    8005:  # Blog Service Port
      mode: PERMISSIVE
    8000:  # API Gateway Port
      mode: PERMISSIVE
    8001:  # User Service Port
      mode: PERMISSIVE
    8002:  # Auth Service Port
      mode: PERMISSIVE
```

### 중기 (근본 해결) - Gateway mTLS 인증 설정

#### 방법 1: DestinationRule에서 Gateway 트래픽 제외
```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: prod-from-gateway
  namespace: titanium-prod
spec:
  host: "*.titanium-prod.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: DISABLE
  subsets:
  - name: from-ingress
    trafficPolicy:
      tls:
        mode: DISABLE
```

#### 방법 2: Gateway에서 mTLS 클라이언트 인증서 사용
```yaml
# istio-system namespace에 titanium-prod ServiceAccount 인증 설정
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: ingress-gateway-mtls
  namespace: istio-system
spec:
  selector:
    matchLabels:
      app: istio-ingressgateway
  mtls:
    mode: STRICT
```

### 장기 (Architecture 개선)
1. **Namespace 분리 전략 재검토**
   - Gateway와 Application을 동일 Namespace로 이동
   - 또는 Service Mesh 외부에서 Gateway 운영

2. **mTLS 정책 계층화**
   - Public 트래픽: PERMISSIVE
   - Internal 서비스 간: STRICT
   - Database/Cache: DISABLE

3. **Authorization Policy 추가**
   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: ingress-to-services
     namespace: titanium-prod
   spec:
     action: ALLOW
     rules:
     - from:
       - source:
           namespaces: ["istio-system"]
           principals: ["cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"]
   ```

## 테스트 방법

### 임시 조치 적용 후 테스트
```bash
# PeerAuthentication 수정 후
kubectl apply -f k8s-manifests/overlays/gcp/istio/peer-authentication.yaml

# 테스트 요청
curl -k https://34.64.171.141:30444/blog/

# 로그 확인
kubectl logs -n istio-system -l app=istio-ingressgateway --tail=20
```

### E2E 테스트 재실행
```bash
k6 run --insecure-skip-tls-verify tests/e2e/e2e-test.js
```

## 관련 파일
- `k8s-manifests/overlays/gcp/istio/peer-authentication.yaml`
- `k8s-manifests/overlays/gcp/istio/peer-authentication-databases.yaml`
- `k8s-manifests/overlays/gcp/istio/destination-rules.yaml`
- `k8s-manifests/overlays/gcp/istio/virtualservice.yaml`

## 다음 단계
1. PERMISSIVE 모드로 임시 조치 적용
2. E2E 테스트로 정상 동작 확인
3. Gateway mTLS 인증 설정 추가
4. STRICT 모드로 복원 후 재테스트

## 참고 링크
- Istio mTLS: https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- PeerAuthentication: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Cross-namespace mTLS: https://istio.io/latest/docs/ops/best-practices/security/#cross-namespace-policy-and-certificate-configuration
