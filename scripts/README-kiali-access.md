# Kiali 자동 접속 스크립트

동적 IP 환경에서 Kiali에 자동으로 접속하기 위한 스크립트입니다.

## 개요

이 스크립트는 다음 작업을 자동으로 수행합니다:
1. 현재 공인 IP 확인
2. GCP 방화벽 규칙에 현재 IP 추가
3. Kiali URL을 브라우저에서 자동으로 열기

## 스크립트 종류

### 1. kiali-connect.sh (기본 버전)

**특징**:
- 간단하고 빠름
- 현재 IP를 방화벽 규칙에 추가
- IP가 변경될 때마다 계속 누적됨

**사용 방법**:
```bash
./scripts/kiali-connect.sh
```

**추천 대상**: 간단한 사용, IP가 자주 변경되지 않는 환경

---

### 2. kiali-connect-advanced.sh (고급 버전) - 추천

**특징**:
- IP 사용 이력 추적 (~/.kiali-ip-history)
- 최근 10개 IP만 유지 (자동 정리)
- 30일 이상 된 IP 기록 자동 삭제
- 방화벽 규칙 최적화

**사용 방법**:
```bash
./scripts/kiali-connect-advanced.sh
```

**추천 대상**: IP가 자주 변경되는 환경, 장기 사용

---

## 사전 요구사항

### 1. gcloud CLI 인증

```bash
# gcloud 로그인 (한 번만 실행)
gcloud auth login

# 기본 프로젝트 설정
gcloud config set project titanium-k3s-1765951764
```

### 2. 필요한 권한

실행하는 계정에 다음 권한이 필요합니다:
- `compute.firewalls.get`
- `compute.firewalls.update`

IAM Role: `Compute Security Admin` 또는 `Editor`

### 3. 필요한 도구

- `curl`: IP 확인
- `gcloud`: GCP 방화벽 규칙 업데이트
- `bash`: 스크립트 실행

## 실행 예시

### 기본 버전
```bash
$ ./scripts/kiali-connect.sh
=== Kiali 자동 접속 스크립트 ===
현재 IP 확인 중...
현재 IP: 14.35.115.202
방화벽 규칙 확인 중...
현재 IP를 방화벽 규칙에 추가 중...
[OK] 방화벽 규칙 업데이트 완료

=== Kiali 접속 정보 ===
URL: http://34.50.8.19:31200/kiali

브라우저를 여는 중...
=== 접속 완료 ===
```

### 고급 버전
```bash
$ ./scripts/kiali-connect-advanced.sh
=== Kiali 자동 접속 스크립트 (고급) ===
현재 IP 확인 중...
현재 IP: 14.35.115.202
방화벽 규칙 확인 중...
허용할 IP 목록 생성 중...
방화벽 규칙 업데이트 중...
이전: 112.218.39.251/32,64.236.160.193/32,14.35.115.100/32
이후: 112.218.39.251/32,14.35.115.202/32
[OK] 방화벽 규칙 업데이트 완료

=== Kiali 접속 정보 ===
URL: http://34.50.8.19:31200/kiali
현재 허용된 IP 개수: 2

브라우저를 여는 중...
=== 접속 완료 ===

팁: IP 기록은 ~/.kiali-ip-history에 저장됩니다.
팁: 최대 10개의 최근 IP가 유지됩니다.
```

## 별칭 설정 (선택)

자주 사용한다면 shell 별칭을 설정하면 편리합니다.

**bash/zsh 사용자**:
```bash
# ~/.bashrc 또는 ~/.zshrc에 추가
alias kiali='~/path/to/Monitoring-v3/scripts/kiali-connect-advanced.sh'

# 적용
source ~/.bashrc  # 또는 source ~/.zshrc
```

**사용**:
```bash
kiali
```

## 환경 변수를 통한 설정 커스터마이징

스크립트는 환경 변수를 통해 설정을 변경할 수 있습니다.

### 지원하는 환경 변수

| 환경 변수 | 기본값 | 설명 |
|-----------|--------|------|
| `GCP_PROJECT_ID` | `titanium-k3s-1765951764` | GCP 프로젝트 ID |
| `KIALI_FIREWALL_RULE` | `titanium-k3s-allow-dashboards` | 방화벽 규칙 이름 |
| `KIALI_MASTER_IP` | `34.50.8.19` | Kubernetes Master Node IP |
| `KIALI_PORT` | `31200` | Kiali NodePort |
| `KIALI_BASE_IP` | (없음) | 항상 유지할 고정 IP (CIDR 형식) |
| `KIALI_MAX_IPS` | `10` | 최대 허용 IP 개수 (고급 버전만) |

### 사용 예시

```bash
# 환경 변수로 설정 오버라이드
export KIALI_BASE_IP="112.218.39.251/32"
export KIALI_MAX_IPS=5
./scripts/kiali-connect-advanced.sh

# 또는 한 줄로 실행
KIALI_BASE_IP="112.218.39.251/32" ./scripts/kiali-connect-advanced.sh
```

### 영구 설정 (선택)

```bash
# ~/.bashrc 또는 ~/.zshrc에 추가
export KIALI_BASE_IP="YOUR_STATIC_IP/32"
export GCP_PROJECT_ID="your-project-id"
```

## 문제 해결

### 1. "현재 IP를 확인할 수 없습니다" 오류

**원인**: 인터넷 연결 문제 또는 모든 IP 확인 서비스 장애

**해결**:
```bash
# 수동으로 IP 확인 (여러 서비스 시도)
curl ifconfig.me
curl icanhazip.com
curl ipinfo.io/ip
curl api.ipify.org
```

스크립트는 자동으로 4개의 서비스를 순차적으로 시도합니다.

### 2. 권한 오류

**오류**:
```
ERROR: (gcloud.compute.firewall-rules.update) PERMISSION_DENIED
```

**해결**:
```bash
# 현재 계정 확인
gcloud auth list

# 권한이 있는 계정으로 재로그인
gcloud auth login
```

### 3. 브라우저가 열리지 않음

**원인**: OS별 브라우저 실행 명령 차이

**해결**: 스크립트 출력된 URL을 수동으로 복사하여 브라우저에서 열기
```
http://34.50.8.19:31200/kiali
```

### 4. IP 기록 파일 확인

```bash
# IP 기록 확인
cat ~/.kiali-ip-history

# 형식: IP,타임스탬프
# 14.35.115.202,1737532800
# 64.236.160.193,1737446400

# 수동으로 기록 삭제
rm ~/.kiali-ip-history
```

## 보안 고려사항

### 1. 최소 권한 원칙

스크립트 실행 계정에 최소한의 권한만 부여:
```bash
# Custom IAM Role 생성 (선택)
gcloud iam roles create KialiFirewallManager \
    --project=titanium-k3s-1765951764 \
    --title="Kiali Firewall Manager" \
    --permissions=compute.firewalls.get,compute.firewalls.update
```

### 2. IP 개수 제한

고급 버전은 최대 10개 IP만 유지하여 방화벽 규칙 비대화 방지

### 3. 환경 변수를 통한 설정

민감한 IP 정보는 스크립트에 하드코딩하지 않고 환경 변수로 관리

### 4. 로그 확인

방화벽 규칙 변경 이력 확인:
```bash
gcloud logging read "resource.type=gce_firewall_rule AND \
    protoPayload.resourceName:titanium-k3s-allow-dashboards" \
    --limit 10 \
    --project=titanium-k3s-1765951764
```

## 대안 방법

### Cloud Scheduler + Cloud Function (완전 자동화)

주기적으로 IP를 체크하고 변경 시 자동 업데이트하려면 Cloud Function 사용 가능.

**장점**: 완전 자동화
**단점**: 설정 복잡, 추가 비용

자세한 내용은 `docs/kiali-cloud-function-setup.md` 참조 (필요 시 작성)

### VPN 사용

고정 IP를 통한 접속이 필요하다면 Cloud VPN 구성 고려.

## 관련 문서

- Kiali 접속 방법 전체 가이드: `docs/kiali-access-guide.md` (필요 시 작성)
- GCP Firewall 관리: https://cloud.google.com/vpc/docs/firewalls
- Kiali 공식 문서: https://kiali.io/docs/

## 라이선스

이 스크립트는 Titanium Microservices 프로젝트의 일부입니다.
