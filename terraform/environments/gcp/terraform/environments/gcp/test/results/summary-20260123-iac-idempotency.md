# IaC 기반 Kiali Service NodePort 설정 및 재검증 결과

**일시**: 2026-01-23 15:55 KST
**목적**: Kiali Service를 IaC 원칙에 맞게 NodePort로 설정하고 전체 서비스 재검증

---

## 1. 변경 사항

### 1.1 Kustomize Patch 추가

**파일**: `k8s-manifests/overlays/gcp/istio/kiali-service-patch.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kiali
  namespace: istio-system
spec:
  type: NodePort
  ports:
    - name: http
      port: 20001
      protocol: TCP
      targetPort: 20001
      nodePort: 31200
```

### 1.2 Kustomization.yaml 업데이트

**파일**: `k8s-manifests/overlays/gcp/kustomization.yaml`

추가된 섹션:
```yaml
patchesStrategicMerge:
  - istio/kiali-service-patch.yaml
```

### 1.3 Git Commit

```
fix(istio): Kiali Service NodePort 설정을 위한 Kustomize patch 추가

Kiali Helm chart가 service.type values를 지원하지 않아 Kustomize patch로 해결.
```

---

## 2. 검증 결과

### 2.1 서비스 접근 테스트

| 서비스 | Port | 결과 | 상세 |
|--------|------|------|------|
| Grafana | 31300 | 성공 | HTTP 302 (Login 리다이렉트) |
| Prometheus | 31090 | 성공 | HTTP 405 (HEAD 미지원, GET 정상) |
| Kiali | 31200 | 성공 | HTTP 200 OK |

### 2.2 Kiali Service 검증

```bash
$ kubectl get svc kiali -n istio-system
NAME    TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)                          AGE
kiali   NodePort   10.43.74.148   <none>        20001:31200/TCP,9090:31739/TCP   56m
```

**결과**: NodePort 31200으로 정상 설정됨

### 2.3 Blog Service -> Auth Service 통신 테스트

**테스트 방법**:
```bash
kubectl exec -n titanium-prod $BLOG_POD -c blog-service-container -- \
  python -c "import urllib.request; response = urllib.request.urlopen('http://prod-auth-service:8002/health'); print(response.status, response.read().decode('utf-8'))"
```

**결과**:
```
200 {"status":"ok","service":"auth-service"}
```

**결과**: NetworkPolicy 적용 후에도 Blog -> Auth 통신 정상 작동

---

## 3. 발견된 이슈

### 3.1 Kiali Helm Chart Service 설정 미지원

**문제**: Kiali Helm chart 2.4.0이 ArgoCD Application values에 설정된 `service.type: NodePort`를 무시함

**원인**: Kiali Helm chart의 values schema가 `service` 키를 직접 지원하지 않음

**해결**: kubectl patch 명령으로 Service Type 직접 수정
```bash
kubectl patch svc kiali -n istio-system -p '{"spec":{"type":"NodePort","ports":[...]}}'
```

**향후 과제**: Terraform 또는 ArgoCD Application 레벨에서 IaC 방식으로 관리하도록 개선 필요

### 3.2 Istio Gateway 경로 매핑

**현상**: `/api/blogs` 경로로 503 에러 발생

**원인**: VirtualService가 `/blog` 경로로 매핑 (`/api/blogs` 아님)

**상태**: 문서화만 진행 (기존 설계 의도에 따름)

---

## 4. 최종 검증 결과 요약

| 항목 | 예상 결과 | 실제 결과 | 상태 |
|------|-----------|-----------|------|
| Kiali Service Type | NodePort | NodePort | 성공 |
| Kiali NodePort | 31200 | 31200 | 성공 |
| Kiali 외부 접근 | 200 OK | 200 OK | 성공 |
| Grafana 외부 접근 | 302/200 | 302 (Login) | 성공 |
| Prometheus 외부 접근 | 200/405 | 405 (HEAD) | 성공 |
| Blog -> Auth 통신 | 200 OK | 200 OK | 성공 |

---

## 5. 결론

1. Kiali Service를 NodePort(31200)로 성공적으로 변경
2. Kustomize patch 파일이 Git에 추가되었으나, 실제 적용은 kubectl patch로 수행
3. NetworkPolicy 적용 후에도 Blog -> Auth 서비스 간 통신 정상 작동 확인
4. 모니터링 스택(Grafana, Prometheus, Kiali) 외부 접근 모두 정상

**후속 작업**: Kiali Service의 IaC 관리 방안 검토 (Terraform ArgoCD Application 또는 Helm values override)
