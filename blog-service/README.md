# Blog Service (blog-service)

![Blog Service](../../docs/demo/01-blog-main.png)

## 1. 개요
- **블로그 기능 제공 서비스**: `blog-service`는 블로그 게시물(Post)의 CRUD(생성, 조회, 수정, 삭제) 기능을 담당하는 Microservice로, Python의 **FastAPI**를 사용하여 개발됨

- **SPA 프론트엔드 내장**: 이 Service는 게시물 관리를 위한 API뿐만 아니라, 사용자가 직접 상호작용할 수 있는 SPA(Single Page Application) 형태의 웹 UI를 함께 제공함. UI는 `templates`와 `static` 폴더에 저장된 HTML, CSS, JavaScript 파일로 구성됨

- **유연한 데이터 관리**: 게시물 데이터는 `USE_POSTGRES` 환경변수에 따라 **PostgreSQL** 또는 **SQLite** 중 선택하여 저장됨. Production 환경에서는 PostgreSQL, 로컬 개발 환경에서는 SQLite(`blog.db`)를 사용

## 2. 핵심 기능 및 책임
- **게시물 관리 (Post Management)**: 게시물의 생성, 목록 조회, 상세 조회, 수정, 삭제 기능을 위한 API 엔드포인트를 제공

- **인증 및 인가 (Authentication & Authorization)**: 게시물 생성, 수정, 삭제와 같이 보호가 필요한 기능에 접근할 때, `auth-service`와 연동하여 사용자의 JWT 토큰을 검증함. 또한, 게시물 수정 및 삭제는 **게시물을 작성한 본인**만 가능하도록 인가(Authorization) 로직을 포함

- **웹 UI 제공**: `Jinja2` 템플릿 엔진을 사용하여 `index.html`을 렌더링하고, 정적 파일(JS, CSS)을 직접 서빙하여 사용자에게 완전한 블로그 웹 애플리케이션을 제공

- **모니터링 지원**: `api-gateway`의 상태 수집을 위한 헬스 체크(`- /health`) 및 통계(`- /stats`) 엔드포인트를 지원

## 3. 기술적 구현 (`blog_service.py`, `static/js/app.js`)
- 백엔드는 **FastAPI**로, 데이터베이스는 **PostgreSQL** 또는 **SQLite**를 환경에 따라 선택하여 사용하며, 인증을 위해 `auth-service`와 비동기 HTTP 통신(`aiohttp`)을 수행

### 3.1. 인증 및 인가 처리 (`require_user` 함수)
- `blog-service`의 핵심 보안 기능은 FastAPI의 의존성 주입(Dependency Injection)을 통해 구현된 `require_user` 함수에 의해 처리됨
1.  **토큰 추출**: API 요청 헤더에서 `Authorization: Bearer <token>` 형식의 JWT를 추출
2.  **토큰 검증 요청**: `aiohttp`를 사용하여 `auth-service`의 `/verify` 엔드포인트로 토큰 검증을 비동기적으로 요청
3.  **사용자 정보 반환**: 토큰이 유효하면, `auth-service`는 토큰에 포함된 사용자 정보(예: `username`)를 반환함. 이 사용자 이름은 게시물 생성 시 `author` 필드를 채우거나, 수정/삭제 시 권한을 확인하는 데 사용됨
4.  **권한 확인 (인가)**: `PATCH /api/posts/{id}` 및 `DELETE /api/posts/{id}` 엔드포인트에서는 DB에서 게시물 정보를 조회하여, 현재 **로그인된 사용자와 게시물의 작성자(`author`)가 일치하는지**를 추가로 확인. 일치하지 않으면 `403 Forbidden` 에러를 반환하여 권한 없는 수정을 방지

### 3.2. 프론트엔드(SPA) 로직 (`app.js`)
- **클라이언트 사이드 라우팅**: URL 해시(`#`)를 기반으로 페이지 이동 없이 동적으로 뷰(목록, 상세, 글쓰기 등)를 렌더링
- **JWT 관리**: 로그인 성공 시 `auth-service`로부터 받은 JWT를 브라우저의 `sessionStorage`에 저장. 이후 인증이 필요한 API를 호출할 때마다 이 토큰을 `Authorization` 헤더에 담아 전송
- **동적 UI**: 로그인 상태와 게시물 작성자 정보를 비교하여, 사용자에게 '수정' 및 '삭제' 버튼을 동적으로 보여주거나 숨김

## 4. 제공 API 엔드포인트
|경로|메서드|인증|설명|
|:---|:---|:--:|:---|
|`/blog/api/posts`|`GET`|X|전체 게시물 목록을 페이지네이션과 함께 조회|
|`/blog/api/posts`|`POST`|O|새로운 게시물을 생성. 작성자는 인증된 사용자로 자동 설정|
|`/blog/api/posts/{id}`|`GET`|X|특정 ID를 가진 게시물의 상세 정보를 조회|
|`/blog/api/posts/{id}`|`PATCH`|O|게시물 정보를 수정. 작성자 본인만 가능|
|`/blog/api/posts/{id}`|`DELETE`|O|게시물을 삭제. 작성자 본인만 가능|

## 5. 웹 인터페이스 엔드포인트
|경로|메서드|설명|
|:---|:---|:---|
|`/blog/*`|`GET`|블로그 SPA (`index.html`)를 렌더링. 클라이언트 사이드 라우팅을 지원|
|`/blog/static/*`|`GET`|JavaScript, CSS 등 정적 파일을 제공|

## 6. Container화 (`Dockerfile`)
- **베이스 이미지**: `python:3.11-slim`을 사용하여 경량화된 이미지를 생성
- **정적 파일 포함**: `templates`와 `static` 디렉터리를 Container 이미지 안으로 복사하여, Service가 직접 웹 UI를 서빙할 수 있도록 함
- **애플리케이션 실행**: `uvicorn` ASGI 서버를 사용하여 `8005` 포트에서 FastAPI 앱을 실행

## 7. 설정
- `AUTH_SERVICE_URL`: JWT 토큰 검증을 위해 호출할 Auth Service의 주소
- `REDIS_HOST`: Redis 서버의 호스트 이름 (기본값: `redis-service`)
- `REDIS_PORT`: Redis 서버의 포트 (기본값: `6379`)
- `USE_POSTGRES`: PostgreSQL 사용 여부 (`true`/`false`, 기본값: `false`)
- `POSTGRES_HOST`: PostgreSQL 서버 호스트 (기본값: `postgresql-service`)
- `POSTGRES_PORT`: PostgreSQL 서버 포트 (기본값: `5432`)
- `POSTGRES_DB`: PostgreSQL 데이터베이스 이름 (기본값: `titanium`)
- `POSTGRES_USER`: PostgreSQL 사용자 (기본값: `postgres`)
- `POSTGRES_PASSWORD`: PostgreSQL 비밀번호
- `POSTGRES_SSLMODE`: PostgreSQL SSL 모드 (기본값: `disable`)
- `BLOG_DATABASE_PATH`: SQLite 사용 시 데이터베이스 파일 경로 (기본값: `/app/blog.db`)