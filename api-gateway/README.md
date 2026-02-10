# API Gateway Service

## 1. 개요
- API 게이트웨이는 Microservice 아키텍처의 단일 진입점(Single Entry Point) 역할을 수행하는 핵심 서비스
- Go 언어로 작성되었으며, 외부로부터 들어오는 모든 API 요청을 받아 적절한 내부 서비스로 라우팅하는 리버스 프록시(Reverse Proxy) 기능을 담당
- 해당 Service를 통해 클라이언트는 여러 내부 Service의 주소를 직접 알 필요 없이, API 게이트웨이의 주소 하나만으로 시스템의 모든 기능에 접근할 수 있음

## 2. 핵심 기능 및 책임
- **요청 라우팅 (Request Routing)**: `/api/` 경로로 들어온 요청의 세부 경로를 분석하여 `auth-service`, `user-service`, `blog-service` 등 적절한 Microservice로 전달
- **경로 재작성 (Path Rewriting)**: 일부 요청에 대해 외부에서 사용하는 경로를 내부 Service가 이해하는 경로로 변환 (예: `/api/register` -> `/users`)
- **안정성 확보 (Stability)**: 내부 서비스 호출 시와 클라이언트 요청 수신 시에 각각 타임아웃을 설정하여 특정 Service의 장애가 전체 시스템으로 전파되는 것을 방지
- **헬스 체크 및 모니터링 지원**: Kubernetes와 같은 오케스트레이션 도구를 위한 헬스 체크(`- /health`) 엔드포인트와, `api-gateway`가 Service Status를 수집할 수 있도록 간단한 통계(`- /stats`) 엔드포인트를 제공

## 3. 기술적 구현 (main.go)
- API 게이트웨이는 Go의 표준 라이브러리인 `net/http`와 `net/http/httputil`을 사용하여 효율적인 리버스 프록시 서버를 구현

### 3.1. 초기화 및 설정
- 서버가 시작되면 `getEnv` 함수를 통해 환경 변수에서 각 내부 Service의 URL(`USER_SERVICE_URL`, `AUTH_SERVICE_URL` 등)과 게이트웨이 자체의 포트 번호(`API_GATEWAY_PORT`)를 읽어옴
- 각 Service 주소에 대해 `httputil.NewSingleHostReverseProxy`를 사용하여 리버스 프록시 인스턴스를 생성

### 3.2. 타임아웃을 통한 안정성 강화 (장애 전파 방지)
특정 Service가 2초 내에 응답하지 않으면 호출을 실패 처리하여 게이트웨이가 무한정 대기하는 상황을 방지

- **서버 타임아웃 (`http.Server`)**: 외부 클라이언트로부터 요청을 받을 때 적용됨
    - `ReadHeaderTimeout: 2s`: 요청 헤더를 읽는 데 걸리는 최대 시간
    - `WriteTimeout: 10s`: 응답을 작성하는 데 걸리는 최대 시간
    - `IdleTimeout: 60s`: 유휴(Keep-Alive) 연결을 유지하는 최대 시간
- **전송 타임아웃 (`http.Transport`)**: 게이트웨이가 내부 Microservice를 호출할 때 적용됨
    - `ResponseHeaderTimeout: 2s`: 요청 후 응답 헤더를 받기까지의 최대 대기 시간
    - `IdleConnTimeout: 30s`: 재사용 가능한 유휴 커넥션을 유지하는 시간

### 3.3. 라우팅 로직
핵심 라우팅 로직은 `/api/`로 시작하는 모든 요청을 처리하는 핸들러에 구현되어 있음

```go
// main.go
mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
    path := r.URL.Path
    trimmedPath := strings.TrimPrefix(path, "/api")

    // ... 라우팅 분기 ...
})
```

요청 경로는 다음과 같은 규칙에 따라 각기 다른 서비스로 전달됨

|요청 경로 (Path)|대상 서비스|프록시 경로 (Proxy Path)|설명|
|:---|:---|:---|:---|
|POST /api/login|auth-service|/login|로그인 요청을 Auth Service로 전달|
|POST /api/register|user-service|/users|경로 재작성: 클라이언트의 /register 요청을 user-service의 /users POST API로 변환하여 전달|
|GET /api/users/*|user-service|/users/*|사용자 정보 관련 요청을 User Service로 전달|
|GET/POST/PATCH/DELETE /api/posts/*|blog-service|/api/posts/*|경로 유지: 블로그 관련 요청은 /api 접두사를 포함한 전체 경로를 그대로 blog-service로 전달|
|그 외|-|-|404 Not Found 응답을 반환|

## 4. 제공 엔드포인트
|경로|메서드|설명|
|:---|:---|:---|
|`/api/*`|`ANY`|내부 서비스로 프록시되는 메인 API 엔드포인트|
|`/health`|`GET`|Service의 상태를 확인하는 헬스 체크 엔드포인트입니다. 항상 200 OK를 반환|
|`/stats`|`GET`|`api-gateway`가 모니터링을 위해 사용하는 통계 엔드포인트, `{ "api-gateway": { "service_status": "online" } }` 형식의 JSON을 반환|

## 5. Container화 (Dockerfile)
API 게이트웨이는 효율적인 배포를 위해 `Multi-stage Docker build`를 사용, 이를 통해 Go 런타임이나 운영체제 도구가 포함되지 않은 초경량(ultra-lightweight)의 보안성이 높은 Container 이미지를 만듦

- Build Stage: `golang:1.24-alpine` 이미지를 기반으로 소스 코드를 정적 바이너리 파일(- /server)로 컴파일

- Final Stage: `scratch 이미지(매우 작은 이미지)`에 빌드된 바이너리 파일 하나만 복사하여 최종 이미지를 생성

6. 설정
API 게이트웨이는 아래 `환경 변수`를 통해 설정을 관리, 해당 값들은 Kubernetes `ConfigMap`을 통해 주입됨

- **API_GATEWAY_PORT**: 게이트웨이 서버가 실행될 `포트(기본값: 8000)`

- **USER_SERVICE_URL**: User Service의 주소

- **AUTH_SERVICE_URL**: Auth Service의 주소

- **BLOG_SERVICE_URL**: Blog Service의 주소

