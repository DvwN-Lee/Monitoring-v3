# Monitoring-v3/user-service/user_service.py
# Version: 1.3.0 - Security Enhancement (CORS, Rate Limiting, Security Headers)

import os
import re
import logging
from fastapi import FastAPI, HTTPException, Depends, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, EmailStr, Field, field_validator
from typing import Optional
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response
from prometheus_fastapi_instrumentator import Instrumentator
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded

try:
    from prometheus_fastapi_instrumentator.metrics import request_latency
except ImportError:
    from prometheus_fastapi_instrumentator import metrics as _metrics

    def request_latency(*args, **kwargs):
        return _metrics.latency(*args, **kwargs)

from database_service import UserServiceDatabase
from cache_service import CacheService

# Reserved username list (보안 강화)
RESERVED_USERNAMES = {'admin', 'root', 'system', 'api', 'auth', 'user', 'blog', 'www', 'mail', 'ftp', 'localhost'}

class UserIn(BaseModel):
    username: str = Field(..., min_length=3, max_length=50)
    email: EmailStr
    password: str = Field(..., min_length=8, max_length=200)

    @field_validator('username')
    @classmethod
    def validate_username(cls, v: str) -> str:
        if not re.match(r'^[a-zA-Z0-9_]+$', v):
            raise ValueError('Username must contain only alphanumeric characters and underscores')
        # Reserved username 차단 (Gemini recommendation)
        if v.lower() in RESERVED_USERNAMES:
            raise ValueError('This username is reserved')
        return v

    @field_validator('password')
    @classmethod
    def validate_password_complexity(cls, v: str) -> str:
        if not re.search(r'[A-Z]', v):
            raise ValueError('Password must contain at least one uppercase letter')
        if not re.search(r'[a-z]', v):
            raise ValueError('Password must contain at least one lowercase letter')
        if not re.search(r'\d', v):
            raise ValueError('Password must contain at least one digit')
        if not re.search(r'[!@#$%^&*(),.?":{}|<>]', v):
            raise ValueError('Password must contain at least one special character')
        return v

class UserOut(BaseModel):
    id: int
    username: str
    email: EmailStr

class Credentials(BaseModel):
    username: str
    password: str

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger('UserServiceApp')

app = FastAPI()
db = UserServiceDatabase()
cache = CacheService()

# === Security Headers Middleware ===
class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    """보안 헤더를 추가하는 Middleware (Gemini recommendation 반영)"""
    async def dispatch(self, request: Request, call_next) -> Response:
        response = await call_next(request)
        # HSTS - HTTPS 강제
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        # Clickjacking 방지
        response.headers["X-Frame-Options"] = "DENY"
        # MIME type sniffing 방지
        response.headers["X-Content-Type-Options"] = "nosniff"
        # XSS Filter (legacy browsers)
        response.headers["X-XSS-Protection"] = "1; mode=block"
        # Referrer Policy
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        # Permissions Policy
        response.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=()"
        # CSP - API Service는 strict 정책 적용
        response.headers["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'"
        # Cache-Control - 민감한 데이터 캐싱 방지
        response.headers["Cache-Control"] = "no-store"
        return response

app.add_middleware(SecurityHeadersMiddleware)

# === CORS 설정 ===
_origins_raw = os.getenv("ALLOWED_ORIGINS", "")
if not _origins_raw:
    logger.warning("ALLOWED_ORIGINS not set. CORS will reject all cross-origin requests.")
ALLOWED_ORIGINS = [o.strip() for o in _origins_raw.split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization", "X-Requested-With"],
)

# === Rate Limiting 설정 ===
limiter = Limiter(key_func=get_remote_address)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# === Unified Error Response Handler ===
ERROR_TYPES = {
    400: "BadRequest",
    401: "Unauthorized",
    403: "Forbidden",
    404: "NotFound",
    429: "TooManyRequests",
    500: "InternalServerError",
    502: "BadGateway",
}

async def http_exception_handler(request: Request, exc: HTTPException):
    """표준화된 에러 응답 형식"""
    from fastapi.responses import JSONResponse
    error_type = ERROR_TYPES.get(exc.status_code, "Error")
    detail = exc.detail if isinstance(exc.detail, str) else str(exc.detail)
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": error_type,
            "message": detail,
            "status_code": exc.status_code
        }
    )

app.add_exception_handler(HTTPException, http_exception_handler)

@app.on_event("startup")
async def startup_event():
    """Initialize database connection pool on startup."""
    await db.initialize()
    await cache.initialize()

@app.on_event("shutdown")
async def shutdown_event():
    """Close database and cache connections on shutdown."""
    await db.close()
    await cache.close()

# Prometheus 메트릭 설정
# 히스토그램 버킷을 세밀하게 설정하여 정확한 P95/P99 계산 가능
from prometheus_client import Counter
from prometheus_fastapi_instrumentator.metrics import Info

REQUEST_LATENCY_BUCKETS = (
    0.001,
    0.005,
    0.01,
    0.025,
    0.05,
    0.075,
    0.1,
    0.25,
    0.5,
    0.75,
    1.0,
    2.5,
    5.0,
    10.0,
)

# 커스텀 메트릭: http_requests_total_custom
# api-gateway와 동일한 형식의 status 레이블(2xx, 4xx, 5xx)을 사용
http_requests_total_custom = Counter(
    "http_requests_total",
    "Total number of HTTP requests",
    ("method", "status"),
)

def http_requests_total_custom_metric(info: Info) -> None:
    status_code = info.response.status_code
    status_group = "unknown"
    if 200 <= status_code < 300:
        status_group = "2xx"
    elif 300 <= status_code < 400:
        status_group = "3xx"
    elif 400 <= status_code < 500:
        status_group = "4xx"
    elif 500 <= status_code < 600:
        status_group = "5xx"
    
    http_requests_total_custom.labels(info.method, status_group).inc()

def configure_metrics(application: FastAPI) -> None:
    """Configure Prometheus request latency metrics with backward-compatible buckets."""
    try:
        instrumentator = Instrumentator(buckets=REQUEST_LATENCY_BUCKETS)
    except TypeError as exc:
        if "buckets" not in str(exc):
            raise
        instrumentator = Instrumentator()
        instrumentator.add(
            request_latency(buckets=REQUEST_LATENCY_BUCKETS)
        )

    # 커스텀 메트릭 추가
    instrumentator.add(http_requests_total_custom_metric)
    instrumentator.instrument(application).expose(application)


configure_metrics(app)

# --- User Service의 통계 및 DB/Cache 상태를 반환하는 엔드포인트 ---
@app.get("/stats")
async def handle_stats():
    # DB와 Cache의 상태를 실시간으로 확인
    is_db_healthy = await db.health_check()
    is_cache_healthy = await cache.ping()

    # 전체 Service Status 결정
    service_status = "online"
    if not is_db_healthy or not is_cache_healthy:
        service_status = "degraded"

    return {
        "user_service": {
            "service_status": service_status,
            # 대시보드가 인식할 수 있는 키로 DB와 Cache 상태를 제공
            "database": {
                "status": "healthy" if is_db_healthy else "unhealthy"
            },
            "cache": {
                "status": "healthy" if is_cache_healthy else "unhealthy",
                "hit_ratio": 0 # 이 예제에서는 단순화를 위해 0으로 고정
            }
        }
    }


# ... (기존 /health, /users 엔드포인트들은 그대로 유지) ...
@app.get("/health")
async def handle_health():
    return {"status": "healthy"}

@app.post("/users", response_model=UserOut, status_code=201)
@limiter.limit("10/minute")
async def create_user(request: Request, user: UserIn):
    user_id = await db.add_user(user.username, user.email, user.password)
    if user_id is None:
        raise HTTPException(status_code=400, detail="Username already exists")
    created_user = await db.get_user_by_id(user_id)
    return created_user

@app.get("/users/{username}", response_model=UserOut)
@limiter.limit("120/minute")  # Gemini recommendation: Profile 조회 상향
async def get_user(request: Request, username: str):
    cached_user = await cache.get_user(username)
    if cached_user:
        return cached_user

    user_from_db = await db.get_user_by_username(username)
    if not user_from_db:
        raise HTTPException(status_code=404, detail="User not found")

    await cache.set_user(username, user_from_db)
    return user_from_db

@app.post("/users/verify-credentials")
@limiter.limit("10/minute")
async def verify_credentials(request: Request, creds: Credentials):
    user = await db.verify_user_credentials(creds.username, creds.password)
    if user:
        return user
    raise HTTPException(status_code=401, detail="Invalid credentials")
