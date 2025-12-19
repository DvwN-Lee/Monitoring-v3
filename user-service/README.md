# User Service (user-service)

## 1. 개요
- **사용자 관리 전문 서비스**: `user-service`는 사용자 계정의 생성, 조회, 자격 증명 검증 등 사용자 데이터 관리에 특화된 Microservice임 
- **다중 데이터 저장소 활용**: 사용자 데이터의 영속성은 **SQLite** 데이터베이스를 통해 보장하며, 자주 조회되는 데이터는 **Redis** 인메모리 캐시에 저장하여 응답 성능을 향상시키는 구조를 가짐 
- **백엔드 핵심 서비스**: `auth-service`가 로그인을 처리할 때 사용자의 실제 비밀번호를 확인하는 등, 다른 서비스들이 필요로 하는 핵심 사용자 데이터를 제공하는 역할을 수행함 

## 2. 핵심 기능 및 책임
- **사용자 계정 관리**: 사용자 생성(회원가입), ID 및 사용자 이름 기반의 사용자 정보 조회 기능을 제공 
- **자격 증명 검증**: `auth-service`로부터 요청을 받아, 데이터베이스에 저장된 해시된 비밀번호와 사용자가 입력한 비밀번호를 안전하게 비교하여 인증을 지원
- **성능 최적화 (캐싱)**: 조회된 사용자 정보를 Redis 캐시에 저장하여 반복적인 데이터베이스 접근을 최소화하고, 이를 통해 시스템 전체의 응답 속도를 향상시킴
- **데이터 저장소 상태 모니터링**: `load-balancer`가 DB와 캐시의 현재 상태(정상/비정상)를 파악할 수 있도록 상세한 상태 정보를 `/stats` 엔드포인트를 통해 제공

## 3. 기술적 구현 (`database_service.py`, `cache_service.py`)
- FastAPI를 기반으로 비동기 처리를 지원하며, 데이터베이스와 캐시 로직을 별도의 클래스(`UserServiceDatabase`, `CacheService`)로 분리하여 관리

### 3.1. 데이터베이스 및 비밀번호 관리
- **데이터베이스 상호작용**: `UserServiceDatabase` 클래스는 SQLite DB 연결 및 쿼리 실행을 담당. 여러 비동기 요청이 동시에 DB에 접근할 때 발생할 수 있는 충돌을 방지하기 위해 `asyncio.Lock`을 사용하여 데이터 무결성을 보장
- **안전한 비밀번호 저장**: 사용자의 비밀번호는 `werkzeug.security` 라이브러리를 사용하여 **해시(hash)된 형태로 저장**됨 
    - `generate_password_hash()`: 회원가입 시 비밀번호를 안전한 해시값으로 변환
    - `check_password_hash()`: 로그인 시 사용자가 입력한 비밀번호와 DB에 저장된 해시값을 비교하여 일치 여부를 확인. 이 방식을 통해 원본 비밀번호를 서버에 저장하지 않아도 자격 증명 검증이 가능

### 3.2. 캐시를 통한 성능 최적화 (Cache-Aside 패턴)
`user-service`는 **Cache-Aside(Look-Aside)** 캐싱 전략을 사용하여 DB 부하를 줄임

1.  **캐시 우선 조회**: `/users/{username}` 엔드포인트로 사용자 조회 요청이 들어오면, 먼저 `cache.get_user`를 호출하여 Redis에 해당 사용자 데이터가 있는지 확인
2.  **Cache Hit**: 데이터가 캐시에 존재하면(Cache Hit), DB를 조회하지 않고 즉시 캐시된 데이터를 반환하여 빠른 응답을 제공
3.  **Cache Miss**: 데이터가 캐시에 없으면(Cache Miss), `db.get_user_by_username`을 호출하여 DB에서 데이터를 조회
4.  **캐시 저장**: DB에서 조회한 데이터를 `cache.set_user`를 통해 Redis에 저장. 이때 **3600초(1시간)의 만료 시간(TTL)**을 설정하여 데이터의 정합성을 유지

### 3.3. 모니터링 지원 로직 (`/stats` 엔드포인트)
- 이 Service의 `/stats` 엔드포인트는 단순한 상태 정보(`online`)만 반환하는 다른 서비스와 달리, 자신이 의존하는 **데이터 저장소의 상태를 직접 점검**하여 반환
    - `db.health_check()`: DB에 간단한 쿼리(`SELECT 1`)를 실행하여 연결 상태를 확인
    - `cache.ping()`: Redis 서버에 `PING` 명령을 보내 응답 여부를 확인
    - 이 두 점검 결과를 조합하여 `database`와 `cache`의 상태를 `healthy` 또는 `unhealthy`로 명시적으로 반환함으로써, 대시보드에서 시스템 장애의 원인을 더 정확하게 파악할 수 있도록 돕는다

## 4. 제공 엔드포인트
|경로|메서드|설명|
|:---|:---|:---|
|`/users`|`POST`|새로운 사용자를 생성(회원가입)|
|`/users/{username}`|`GET`|사용자 이름으로 특정 사용자의 정보를 조회|
|`/users/verify-credentials`|`POST`|`auth-service`의 요청을 받아 사용자의 아이디와 비밀번호 유효성을 검증|
|`/health`|`GET`|Service의 기본 상태를 확인하는 헬스 체크 엔드포인트|
|`/stats`|`GET`|`load-balancer`를 위해 DB와 캐시를 포함한 Service의 상세 상태 정보를 반환|

## 5. Container화 (`Dockerfile`)
- **베이스 이미지**: `python:3.11-slim`을 사용하여 Container 이미지의 크기를 최소화
- **의존성 설치**: `requirements.txt`에 명시된 라이브러리(`fastapi`, `uvicorn`, `werkzeug`, `redis` 등)를 설치 
- **애플리케이션 실행**: `uvicorn`을 사용하여 `8001` 포트에서 FastAPI 애플리케이션을 실행

## 6. 설정 (`config.py`)
- `DATABASE_PATH`: SQLite 데이터베이스 파일이 저장될 경로. Container 내부의 `/data/app.db`를 가리키며, 이 경로는 Kubernetes PVC(PersistentVolumeClaim)와 연결되어 데이터 영속성을 보장
- `REDIS_HOST`: 접속할 Redis 서버의 호스트 이름
- `REDIS_PORT`: 접속할 Redis 서버의 포트