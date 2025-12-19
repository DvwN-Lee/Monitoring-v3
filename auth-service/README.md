# Authentication Service (auth-service)

## 1. 개요
- **인증 전문 Microservice**: `auth-service`는 시스템 전체의 사용자 인증을 전담하는 서비스로, Python과 FastAPI 프레임워크를 기반으로 구축됨

- **JWT 기반 인증**: 사용자의 로그인 요청을 처리하여 자격 증명이 유효할 경우, JWT(JSON Web Token)를 발급함. 또한, 다른 서비스로부터 전달받은 토큰의 유효성을 검증하는 역할을 수행

- **Service 간 통신**: 인증 과정에서 실제 사용자 정보의 유효성 검증은 `user-service`에 위임함. 이는 Service의 단일 책임 원칙(Single Responsibility Principle)을 따르는 설계임

## 2. 핵심 기능 및 책임
- **사용자 로그인**: 사용자의 아이디와 비밀번호를 받아 `user-service`를 통해 유효성을 검증하고, 성공 시 JWT를 생성하여 반환

- **토큰 발급 (JWT Generation)**: 로그인 성공 시, 사용자 정보(ID, 이름)와 만료 시간을 포함하는 JWT 페이로드를 생성하고, 서버의 비밀 키로 서명하여 안전한 토큰을 발급

- **토큰 검증 (Token Verification)**: 다른 서비스(예: `blog-service`)에서 API 접근 권한을 확인하기 위해 전달한 토큰의 서명, 만료 시간 등을 검증하고 결과를 반환

- **모니터링 지원**: `load-balancer`가 Service Status를 수집할 수 있도록 헬스 체크(`- /health`) 및 간단한 통계(`- /stats`) 엔드포인트를 제공

## 3. 기술적 구현 (`auth_service.py`, `main.py`)
- Python의 비동기 웹 프레임워크인 **FastAPI**를 기반으로 API 서버를 구현했으며, `user-service`와의 통신을 위해 비동기 HTTP 클라이언트 라이브러리인 **aiohttp**를 사용

### 3.1. 로그인 및 JWT 발급 프로세스 (`login` 함수)
- **자격 증명 검증 요청**: `login` 함수는 사용자 이름과 비밀번호를 받으면, `_verify_user_from_service` 헬퍼 함수를 호출함
    - 이 함수는 `aiohttp`를 사용하여 `user-service`의 `/users/verify-credentials` 엔드포인트로 `POST` 요청을 비동기적으로 전송
    - `user-service`는 DB를 조회하여 해당 사용자의 자격 증명이 유효한지 확인하고 결과를 반환
-   **JWT 페이로드 생성**: `user-service`로부터 성공 응답을 받으면, 토큰에 담을 정보를 구성
    - 페이로드에는 `user_id`, `username`, 그리고 **24시간 후 만료되는 시간(`exp`)**이 포함됨
-   **토큰 서명 및 발급**: `PyJWT` 라이브러리를 사용하여 구성된 페이로드를 **HS256 알고리즘**과 환경 변수로 설정된 `JWT_SECRET` 키로 서명하여 최종 토큰을 생성하고 클라이언트에게 반환

### 3.2. 토큰 검증 로직 (`verify_token` 함수)
- 다른 Service가 보호된 리소스에 대한 접근을 요청할 때, `Authorization: Bearer <token>` 헤더를 이 Service의 `/verify` 엔드포인트로 전달
- `verify_token` 함수는 `jwt.decode`를 사용하여 전달된 토큰을 검증
- 검증 과정에서는 **서명의 유효성**과 **토큰의 만료 여부**를 모두 확인
    - **검증 성공**: 토큰에 담겨있던 페이로드(사용자 정보)를 반환
    - **검증 실패**: 토큰이 만료되었거나(`ExpiredSignatureError`), 서명이 유효하지 않을 경우(`InvalidTokenError`) 적절한 에러 메시지를 반환

## 4. 제공 엔드포인트
|경로|메서드|설명|
|:---|:---|:---|
|`/login`|`POST`|사용자 아이디와 비밀번호로 로그인을 시도하고, 성공 시 JWT를 반환|
|`/verify`|`GET`|`Authorization` 헤더로 전달된 JWT의 유효성을 검증|
|`/health`|`GET`|Service의 상태를 확인하는 헬스 체크 엔드포인트. 항상 `200 OK`를 반환|
|`/stats`|`GET`|`load-balancer`가 모니터링을 위해 사용하는 통계 엔드포인트|

## 5. Container화 (`Dockerfile`)
- **베이스 이미지**: `python:3.11-slim`을 사용하여 가볍고 효율적인 환경을 구성
- **의존성 설치**: `requirements.txt`에 명시된 라이브러리(`fastapi`, `uvicorn`, `pyjwt`, `aiohttp`)를 설치
- **애플리케이션 실행**: `uvicorn` ASGI 서버를 사용하여 FastAPI 애플리케이션을 실행

## 6. 설정 (`config.py`)
`auth-service`는 아래 환경 변수를 통해 설정을 관리하며, 이 값들은 Kubernetes `ConfigMap` 또는 `docker-compose.yml`을 통해 주입됨

- `USER_SERVICE_URL`: 인증 정보를 검증하기 위해 호출할 User Service의 주소
- `INTERNAL_API_SECRET`: JWT 서명 및 검증에 사용할 비밀 키
- **(서버 포트)**: Service가 실행될 포트는 코드 내에서 `8002`로 지정되어 있음