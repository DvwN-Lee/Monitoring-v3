# 공통 개선사항

모든 서비스에 적용할 수 있는 공통 개선사항입니다.

## 1. 구조화된 로깅

### 현재 상태

모든 서비스에서 문자열 포맷팅 기반의 로깅을 사용합니다.

```python
# Python 서비스
logger.info(f"User '{username}' logged in successfully")
logger.error(f"Database error: {e}")
```

```go
// Go 서비스
log.Printf("Request to %s completed", path)
```

### 문제점

- 로그 파싱 및 분석이 어려움
- Elasticsearch, Loki 등 로그 수집기에서 필드 추출 불가
- 구조화된 쿼리 불가

### 개선 방안

**Python 서비스 (python-json-logger 사용)**

```python
import logging
from pythonjsonlogger import jsonlogger

def setup_logging():
    logger = logging.getLogger()
    handler = logging.StreamHandler()
    formatter = jsonlogger.JsonFormatter(
        '%(asctime)s %(levelname)s %(name)s %(message)s',
        rename_fields={'asctime': 'timestamp', 'levelname': 'level'}
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    return logger

# 사용 예시
logger.info("user_login", extra={
    "username": username,
    "ip_address": request.client.host,
    "user_agent": request.headers.get("user-agent")
})
```

**Go 서비스 (slog 사용, Go 1.21+)**

```go
import "log/slog"

func main() {
    logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
    slog.SetDefault(logger)

    // 사용 예시
    slog.Info("request_completed",
        slog.String("method", r.Method),
        slog.String("path", r.URL.Path),
        slog.Int("status", recorder.status),
        slog.Duration("duration", duration),
    )
}
```

---

## 2. Prometheus 메트릭 표준화

### 현재 상태

각 서비스마다 메트릭 이름과 레이블이 다릅니다.

### 개선 방안

**표준 메트릭 명명 규칙**

```
# HTTP 요청 관련
http_requests_total{service, method, path, status}
http_request_duration_seconds{service, method, path}
http_request_size_bytes{service, method}
http_response_size_bytes{service, method, status}

# 비즈니스 메트릭
<service>_<operation>_total{...}
<service>_<operation>_duration_seconds{...}

# 의존성 관련
<service>_<dependency>_requests_total{status}
<service>_<dependency>_duration_seconds{}
```

**Python 서비스 표준화 예시**

```python
from prometheus_client import Counter, Histogram, Gauge

# HTTP 메트릭
HTTP_REQUESTS = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['service', 'method', 'path', 'status']
)

HTTP_DURATION = Histogram(
    'http_request_duration_seconds',
    'HTTP request duration',
    ['service', 'method', 'path'],
    buckets=[0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0]
)

# 의존성 메트릭 (auth-service -> user-service)
DEPENDENCY_REQUESTS = Counter(
    'auth_service_user_service_requests_total',
    'Requests to user-service',
    ['status']
)

DEPENDENCY_DURATION = Histogram(
    'auth_service_user_service_duration_seconds',
    'User-service request duration',
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0]
)

# 캐시 메트릭
CACHE_OPERATIONS = Counter(
    'cache_operations_total',
    'Cache operations',
    ['service', 'operation', 'result']  # result: hit, miss, error
)
```

---

## 3. 분산 추적 (OpenTelemetry)

### 현재 상태

분산 추적이 구현되어 있지 않아, 서비스 간 요청 흐름을 추적할 수 없습니다.

### 개선 방안

**Python 서비스**

```python
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.aiohttp_client import AioHttpClientInstrumentor

def setup_tracing(service_name: str):
    provider = TracerProvider()
    processor = BatchSpanProcessor(OTLPSpanExporter())
    provider.add_span_processor(processor)
    trace.set_tracer_provider(provider)

    # FastAPI 자동 계측
    FastAPIInstrumentor.instrument_app(app)

    # aiohttp 클라이언트 자동 계측
    AioHttpClientInstrumentor().instrument()

# 수동 span 추가
tracer = trace.get_tracer(__name__)

async def verify_token(token: str):
    with tracer.start_as_current_span("verify_token") as span:
        span.set_attribute("token.length", len(token))
        # 토큰 검증 로직
        result = await auth_service.verify(token)
        span.set_attribute("verification.success", result.get("status") == "success")
        return result
```

**Go 서비스**

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/trace"
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

func initTracer() func() {
    exporter, _ := otlptracegrpc.New(context.Background())
    tp := trace.NewTracerProvider(trace.WithBatcher(exporter))
    otel.SetTracerProvider(tp)

    return func() { tp.Shutdown(context.Background()) }
}

// HTTP 핸들러 계측
handler := otelhttp.NewHandler(mux, "api-gateway")
```

---

## 4. CORS 설정 강화

### 현재 상태

모든 서비스에서 `ALLOWED_ORIGINS` 기본값이 `*`로 설정되어 있습니다.

### 개선 방안

```python
# 환경별 CORS 설정
import os

def get_allowed_origins() -> list[str]:
    env = os.getenv("ENVIRONMENT", "development")

    if env == "production":
        # 프로덕션: 명시적 도메인만 허용
        origins = os.getenv("ALLOWED_ORIGINS")
        if not origins:
            raise ValueError("ALLOWED_ORIGINS must be set in production")
        return origins.split(",")
    elif env == "staging":
        return ["https://staging.example.com"]
    else:
        # 개발: localhost 허용
        return ["http://localhost:3000", "http://localhost:8080"]

app.add_middleware(
    CORSMiddleware,
    allow_origins=get_allowed_origins(),
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
    allow_headers=["Authorization", "Content-Type"],
)
```

---

## 5. 의존성 주입 패턴

### 현재 상태

전역 변수로 서비스 인스턴스를 관리합니다.

```python
db = UserServiceDatabase()
cache = CacheService()
auth_service = AuthService()
```

### 개선 방안

**FastAPI Depends 활용**

```python
from fastapi import Depends
from functools import lru_cache

class Settings:
    def __init__(self):
        self.database_url = os.getenv("DATABASE_URL")
        self.redis_url = os.getenv("REDIS_URL")

@lru_cache()
def get_settings() -> Settings:
    return Settings()

async def get_db(settings: Settings = Depends(get_settings)) -> AsyncGenerator:
    db = UserServiceDatabase(settings.database_url)
    await db.initialize()
    try:
        yield db
    finally:
        await db.close()

async def get_cache(settings: Settings = Depends(get_settings)) -> AsyncGenerator:
    cache = CacheService(settings.redis_url)
    await cache.initialize()
    try:
        yield cache
    finally:
        await cache.close()

# 엔드포인트에서 사용
@app.post("/users")
async def create_user(
    user: UserIn,
    db: UserServiceDatabase = Depends(get_db),
    cache: CacheService = Depends(get_cache)
):
    user_id = await db.add_user(user.username, user.email, user.password)
    await cache.invalidate_users()
    return {"id": user_id}
```

---

## 6. 테스트 커버리지

### 현재 상태

단위 테스트가 거의 없고, 통합 테스트는 엔드포인트 가용성만 확인합니다.

### 개선 방안

**테스트 구조**

```
tests/
├── unit/
│   ├── auth_service/
│   │   ├── test_jwt.py
│   │   ├── test_rate_limiting.py
│   │   └── test_validation.py
│   ├── user_service/
│   │   ├── test_database.py
│   │   ├── test_cache.py
│   │   └── test_password.py
│   └── blog_service/
│       ├── test_posts.py
│       └── test_categories.py
├── integration/
│   ├── test_auth_flow.py
│   ├── test_user_registration.py
│   └── test_blog_crud.py
└── e2e/
    └── test_full_workflow.py
```

**pytest fixture 예시**

```python
import pytest
from httpx import AsyncClient
from unittest.mock import AsyncMock

@pytest.fixture
def mock_db():
    db = AsyncMock()
    db.get_user_by_username.return_value = {
        "id": 1,
        "username": "testuser",
        "email": "test@example.com"
    }
    return db

@pytest.fixture
def mock_cache():
    cache = AsyncMock()
    cache.get_user.return_value = None
    return cache

@pytest.fixture
async def client(mock_db, mock_cache):
    app.dependency_overrides[get_db] = lambda: mock_db
    app.dependency_overrides[get_cache] = lambda: mock_cache
    async with AsyncClient(app=app, base_url="http://test") as ac:
        yield ac
    app.dependency_overrides.clear()

@pytest.mark.asyncio
async def test_get_user(client, mock_db):
    response = await client.get("/users/testuser")
    assert response.status_code == 200
    assert response.json()["username"] == "testuser"
    mock_db.get_user_by_username.assert_called_once_with("testuser")
```

---

## 7. 헬스 체크 개선

### 현재 상태

모든 서비스의 `/health` 엔드포인트가 의존성 상태를 확인하지 않고 항상 "healthy"를 반환합니다.

### 개선 방안

**Liveness vs Readiness 분리**

```python
@app.get("/health/live")
async def liveness():
    """서비스 자체 상태 확인 (Kubernetes liveness probe)"""
    return {"status": "alive"}

@app.get("/health/ready")
async def readiness(
    db: UserServiceDatabase = Depends(get_db),
    cache: CacheService = Depends(get_cache)
):
    """의존성 포함 준비 상태 확인 (Kubernetes readiness probe)"""
    checks = {
        "database": await check_database(db),
        "cache": await check_cache(cache),
    }

    all_healthy = all(c["status"] == "healthy" for c in checks.values())

    if not all_healthy:
        raise HTTPException(status_code=503, detail=checks)

    return {"status": "ready", "checks": checks}

async def check_database(db) -> dict:
    try:
        await db.execute("SELECT 1")
        return {"status": "healthy"}
    except Exception as e:
        return {"status": "unhealthy", "error": str(e)}

async def check_cache(cache) -> dict:
    try:
        await cache.ping()
        return {"status": "healthy"}
    except Exception as e:
        return {"status": "unhealthy", "error": str(e)}
```

**Kubernetes 설정**

```yaml
livenessProbe:
  httpGet:
    path: /health/live
    port: 8001
  initialDelaySeconds: 5
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /health/ready
    port: 8001
  initialDelaySeconds: 10
  periodSeconds: 5
```

---

## 8. 설정 관리 개선

### 현재 상태

각 서비스마다 다른 방식으로 환경 변수를 처리합니다.

### 개선 방안

**Pydantic Settings 활용**

```python
from pydantic_settings import BaseSettings
from functools import lru_cache

class Settings(BaseSettings):
    # 서버 설정
    host: str = "0.0.0.0"
    port: int = 8001
    environment: str = "development"

    # 데이터베이스 설정
    database_url: str
    db_pool_min_size: int = 5
    db_pool_max_size: int = 20

    # Redis 설정
    redis_host: str = "localhost"
    redis_port: int = 6379
    cache_ttl: int = 300

    # 보안 설정
    internal_api_secret: str
    jwt_algorithm: str = "RS256"
    jwt_expiry_hours: int = 24

    # 외부 서비스
    auth_service_url: str = "http://auth-service:8002"

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"

@lru_cache()
def get_settings() -> Settings:
    return Settings()

# 사용
settings = get_settings()
```

---

## 9. 에러 응답 표준화

### 현재 상태

서비스마다 에러 응답 형식이 다릅니다.

### 개선 방안

**표준 에러 응답 형식**

```python
from pydantic import BaseModel
from typing import Optional, Any

class ErrorResponse(BaseModel):
    error: str
    message: str
    details: Optional[Any] = None
    trace_id: Optional[str] = None

# 전역 예외 핸들러
@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    trace_id = request.headers.get("X-Trace-ID", str(uuid.uuid4()))
    return JSONResponse(
        status_code=exc.status_code,
        content=ErrorResponse(
            error=http.HTTPStatus(exc.status_code).phrase,
            message=exc.detail,
            trace_id=trace_id
        ).dict()
    )

@app.exception_handler(Exception)
async def generic_exception_handler(request: Request, exc: Exception):
    trace_id = request.headers.get("X-Trace-ID", str(uuid.uuid4()))
    logger.error(f"Unhandled exception: {exc}", exc_info=True, extra={"trace_id": trace_id})
    return JSONResponse(
        status_code=500,
        content=ErrorResponse(
            error="Internal Server Error",
            message="An unexpected error occurred",
            trace_id=trace_id
        ).dict()
    )
```

---

## 10. Circuit Breaker 패턴

### 현재 상태

서비스 간 통신에서 의존 서비스 장애 시 연쇄 실패가 발생할 수 있습니다.

### 개선 방안

**circuitbreaker 라이브러리 활용**

```python
from circuitbreaker import circuit, CircuitBreakerError
import aiohttp

class AuthClient:
    def __init__(self, base_url: str):
        self.base_url = base_url

    @circuit(failure_threshold=5, recovery_timeout=30)
    async def verify_token(self, token: str) -> dict:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                f"{self.base_url}/verify",
                headers={"Authorization": f"Bearer {token}"},
                timeout=aiohttp.ClientTimeout(total=5)
            ) as resp:
                if resp.status != 200:
                    raise Exception(f"Auth service returned {resp.status}")
                return await resp.json()

# 사용
async def get_current_user(token: str):
    try:
        result = await auth_client.verify_token(token)
        return result["data"]
    except CircuitBreakerError:
        logger.warning("Circuit breaker open for auth service")
        raise HTTPException(status_code=503, detail="Auth service temporarily unavailable")
```
