# ADR-004: Istio Service Mesh 도입

**날짜**: 2026-01-15

---

## 상황 (Context)

Microservice 간 통신에서 다음 요구사항이 발생했다:
- mTLS를 통한 Service 간 암호화 통신
- 트래픽 라우팅 및 로드 밸런싱
- 분산 추적(Distributed Tracing) 지원
- Service 간 통신 메트릭 수집

Application 코드 수정 없이 이러한 기능을 Infrastructure 레벨에서 제공해야 한다.

## 결정 (Decision)

Istio Service Mesh를 도입한다. Sidecar Injection을 통해 모든 Application Pod에 Envoy Proxy를 자동 주입하고, Istio Gateway를 통해 외부 트래픽을 라우팅한다.

주요 구성:
- `istiod`: Control Plane (v1.24.2)
- `istio-ingressgateway`: NodePort 기반 Ingress (80:31080, 443:31443)
- `PeerAuthentication`: STRICT mTLS 적용
- `VirtualService` + `Gateway`: 경로 기반 라우팅

## 이유 (Rationale)

| 항목 | Istio | Linkerd | 직접 구현 |
|------|-------|---------|----------|
| mTLS 자동화 | Native | Native | Application 수정 필요 |
| 트래픽 관리 | 강력 (VirtualService, DestinationRule) | 기본적 | 별도 구현 필요 |
| 관측성 | Kiali, Jaeger 통합 | 기본 Dashboard | 별도 구현 |
| 리소스 사용량 | 높음 (~100MB/sidecar) | 낮음 (~10MB) | 없음 |
| 학습 곡선 | 높음 | 보통 | 낮음 |

Istio는 리소스 사용량이 높지만, VirtualService를 통한 세밀한 트래픽 라우팅과 Kiali를 통한 Service Graph 시각화가 가능하다. Monitoring 프로젝트 특성상 관측성이 중요하므로 Istio를 선택했다.

## 결과 (Consequences)

### 긍정적 측면
- Application 코드 수정 없이 mTLS 적용 완료
- Kiali를 통한 Service 간 트래픽 시각화
- VirtualService로 경로 기반 라우팅 (예: `/api/users` -> `user-service`)
- Prometheus 메트릭 자동 수집 (Envoy sidecar stats)

### 부정적 측면 (Trade-offs)
- Pod당 ~100MB 추가 메모리 사용
- Sidecar Injection으로 인한 Pod 시작 시간 증가 (~2-3초)
- NetworkPolicy와의 충돌 가능성 (Istiod 통신 허용 필요)
- Istio CRD 복잡도로 인한 디버깅 난이도 증가
