# ADR-006: Zero Trust NetworkPolicy 모델

**날짜**: 2026-01-25

---

## 상황 (Context)

Kubernetes Cluster 내 Pod 간 통신이 기본적으로 모두 허용된다. 보안 강화를 위해:
- 필요한 통신만 명시적으로 허용 (Least Privilege)
- Service 간 의존 관계 문서화
- 비인가 접근 차단

Istio mTLS와 별개로 Network 레벨에서 추가 방어 계층이 필요하다.

## 결정 (Decision)

Zero Trust 모델 기반의 Kubernetes NetworkPolicy를 적용한다. 모든 Pod에 대해 기본 Deny 정책을 적용하고, 필요한 Ingress/Egress만 명시적으로 허용한다.

적용 범위:
- `api-gateway`: Istio IngressGateway에서만 Ingress 허용
- `auth-service`, `user-service`, `blog-service`: 허용된 Service에서만 Ingress
- `postgresql`, `redis`: Application Service에서만 Ingress
- 모든 Pod: DNS(kube-dns) 및 Istiod 통신 Egress 허용

## 이유 (Rationale)

| 항목 | Zero Trust (명시적 허용) | 기본 허용 + 차단 목록 | NetworkPolicy 미적용 |
|------|-------------------------|---------------------|-------------------|
| 보안 수준 | 높음 | 보통 | 낮음 |
| 관리 복잡도 | 높음 (모든 통신 정의) | 보통 | 낮음 |
| 문서화 효과 | 높음 (의존 관계 명확) | 낮음 | 없음 |
| 신규 Service 추가 | Policy 추가 필요 | 차단 목록 확인 | 즉시 통신 가능 |

Zero Trust 모델은 초기 설정이 복잡하지만, Service 간 의존 관계가 NetworkPolicy YAML에 명시되어 문서화 효과가 있다. 보안 감사 시에도 통신 흐름을 명확히 증명할 수 있다.

## 결과 (Consequences)

### 긍정적 측면
- 명시적으로 허용된 통신만 가능 (Least Privilege)
- NetworkPolicy YAML이 Service 의존 관계 문서 역할
- 침해 발생 시 Lateral Movement 제한
- Istio mTLS와 함께 Defense in Depth 구현

### 부정적 측면 (Trade-offs)
- 신규 Service 추가 시 NetworkPolicy 업데이트 필수
- Istio sidecar 통신(15090, 15012, 15010)도 명시적 허용 필요
- Prometheus scraping을 위한 Monitoring Namespace 허용 규칙 필요
- 디버깅 시 NetworkPolicy로 인한 통신 차단 가능성 고려
