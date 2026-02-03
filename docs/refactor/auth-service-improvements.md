# Auth Service 코드 리뷰 개선사항

## 요약

| 심각도 | 개수 |
|--------|------|
| Critical | 5 |
| High | 5 |
| Medium | 4 |

---

## 1. 코드 품질 개선

### 1.1 네트워크 에러 처리 미흡

- **위치:** `auth-service/auth_service.py:36-47`
- **심각도:** High
- **문제:** 모든 aiohttp 예외를 `None`으로 반환하여 네트워크 오류와 인증 실패를 구분할 수 없음

**현재 코드:**
```python
except aiohttp.ClientError as e:
    logger.error(f"Error connecting to user-service: {e}")
    return None
```

**개선 코드:**
```python
import asyncio

class UserServiceError(Exception):
    """User service 통신 오류"""
    pass

async def _verify_user_from_service(self, username: str, password: str) -> Optional[dict]:
    timeout = aiohttp.ClientTimeout(total=5)
    try:
        session = await self.get_session()
        payload = {"username": username, "password": password}

        async with session.post(
            self.USER_SERVICE_VERIFY_URL,
            json=payload,
            timeout=timeout
        ) as response:
            if response.status == 200:
                return await response.json()
            elif response.status == 401:
                return None  # 인증 실패
            else:
                logger.error(f"User service returned {response.status}")
                raise UserServiceError(f"Unexpected status: {response.status}")

    except asyncio.TimeoutError:
        logger.error("User service request timeout")
        raise UserServiceError("Request timeout")
    except aiohttp.ClientError as e:
        logger.error(f"User service connection error: {e}")
        raise UserServiceError(f"Connection error: {e}")
```

---

### 1.2 user_id None 체크 누락

- **위치:** `auth-service/auth_service.py:49-67`
- **심각도:** Medium
- **문제:** `user_data.get("id")`가 None일 경우 에러 처리 없음

**현재 코드:**
```python
user_id = user_data.get("id")
jwt_payload = {
    'user_id': user_id,  # None이 토큰에 포함될 수 있음
    ...
}
```

**개선 코드:**
```python
user_id = user_data.get("id")
if user_id is None:
    logger.error(f"Invalid user data response: missing 'id' field")
    return {"status": "failed", "message": "Internal error: invalid user data"}

jwt_payload = {
    'user_id': user_id,
    'username': username,
    'exp': datetime.now(timezone.utc) + self.JWT_EXP_DELTA_SECONDS
}
```

---

### 1.3 로깅 중복

- **위치:** `auth-service/main.py:25, 177` 및 `auth-service/auth_service.py:8`
- **심각도:** Low
- **문제:** 동일한 시작 로그가 여러 곳에서 중복되고, 로깅 설정도 중복됨

**개선 코드:**
```python
# main.py에서만 로깅 설정
import logging

def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
    return logging.getLogger(__name__)

logger = setup_logging()

# auth_service.py에서는 getLogger만 사용
logger = logging.getLogger(__name__)
```

---

### 1.4 부적절한 상태 코드 반환

- **위치:** `auth-service/main.py:131-137`
- **심각도:** Medium
- **문제:** 모든 로그인 실패를 401로 반환하여 원인 파악 불가

**현재 코드:**
```python
status_code = 200 if result.get('status') == 'success' else 401
```

**개선 코드:**
```python
if result.get('status') == 'success':
    status_code = 200
elif result.get('error_type') == 'rate_limit':
    status_code = 429  # Too Many Requests
elif result.get('error_type') == 'validation':
    status_code = 400  # Bad Request
elif result.get('error_type') == 'service_unavailable':
    status_code = 503  # Service Unavailable
else:
    status_code = 401  # Unauthorized
```

---

## 2. 보안 개선

### 2.1 JWT 알고리즘 강화

- **위치:** `auth-service/auth_service.py:16-17`
- **심각도:** Critical
- **문제:** HS256(HMAC) 사용으로 키 유출 시 토큰 위조 가능

**현재 코드:**
```python
self.JWT_ALGORITHM = "HS256"
```

**개선 코드:**
```python
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend

class AuthService:
    def __init__(self):
        self.JWT_ALGORITHM = "RS256"
        self.JWT_PRIVATE_KEY = self._load_private_key()
        self.JWT_PUBLIC_KEY = self._load_public_key()

    def _load_private_key(self):
        key_path = os.getenv("JWT_PRIVATE_KEY_PATH", "/secrets/jwt-private.pem")
        with open(key_path, "rb") as f:
            return serialization.load_pem_private_key(
                f.read(),
                password=None,
                backend=default_backend()
            )

    def _load_public_key(self):
        key_path = os.getenv("JWT_PUBLIC_KEY_PATH", "/secrets/jwt-public.pem")
        with open(key_path, "rb") as f:
            return serialization.load_pem_public_key(
                f.read(),
                backend=default_backend()
            )

    def create_token(self, payload: dict) -> str:
        return jwt.encode(payload, self.JWT_PRIVATE_KEY, algorithm=self.JWT_ALGORITHM)

    def verify_token(self, token: str) -> dict:
        return jwt.decode(token, self.JWT_PUBLIC_KEY, algorithms=[self.JWT_ALGORITHM])
```

---

### 2.2 JWT 필수 클레임 추가

- **위치:** `auth-service/auth_service.py:58-63`
- **심각도:** Critical
- **문제:** `iat`, `jti` 등 필수 클레임 누락으로 토큰 무효화 불가

**현재 코드:**
```python
jwt_payload = {
    'user_id': user_id,
    'username': username,
    'exp': datetime.now(timezone.utc) + self.JWT_EXP_DELTA_SECONDS
}
```

**개선 코드:**
```python
import uuid

jwt_payload = {
    'sub': str(user_id),           # Subject (사용자 ID)
    'username': username,
    'iat': datetime.now(timezone.utc),  # Issued At
    'exp': datetime.now(timezone.utc) + self.JWT_EXP_DELTA_SECONDS,
    'jti': str(uuid.uuid4()),      # JWT ID (토큰 무효화용)
    'iss': 'auth-service',         # Issuer
    'aud': 'monitoring-v3',        # Audience
}
```

---

### 2.3 비밀 키 강도 검증

- **위치:** `auth-service/config.py:17-21`
- **심각도:** Critical
- **문제:** 비밀 키 존재만 확인하고 강도 검증 없음

**현재 코드:**
```python
def __post_init__(self):
    if not self.internal_api_secret:
        raise ValueError("INTERNAL_API_SECRET environment variable is required...")
```

**개선 코드:**
```python
import secrets

def __post_init__(self):
    if not self.internal_api_secret:
        raise ValueError("INTERNAL_API_SECRET environment variable is required")

    # 최소 길이 검증 (32바이트 = 256비트)
    if len(self.internal_api_secret) < 32:
        raise ValueError("INTERNAL_API_SECRET must be at least 32 characters")

    # 엔트로피 검증 (단순 문자열 방지)
    if self.internal_api_secret == self.internal_api_secret[0] * len(self.internal_api_secret):
        raise ValueError("INTERNAL_API_SECRET must have sufficient entropy")

    # 개발 환경 약한 키 경고
    weak_patterns = ['password', 'secret', '123456', 'default']
    if any(pattern in self.internal_api_secret.lower() for pattern in weak_patterns):
        import warnings
        warnings.warn("INTERNAL_API_SECRET appears to contain weak patterns")
```

---

### 2.4 Rate Limiting 강화

- **위치:** `auth-service/main.py:48, 132`
- **심각도:** Critical
- **문제:** Rate limit key로 IP만 사용하여 프록시 뒤에서 우회 가능, 로그인 5/분은 너무 느슨함

**현재 코드:**
```python
limiter = Limiter(key_func=get_remote_address)

@limiter.limit("5/minute")
async def handle_login(login: LoginRequest):
```

**개선 코드:**
```python
from slowapi import Limiter
from slowapi.util import get_remote_address

def get_real_ip(request: Request) -> str:
    """X-Forwarded-For 헤더를 고려한 실제 IP 추출"""
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        # 첫 번째 IP가 실제 클라이언트 IP
        return forwarded.split(",")[0].strip()
    return get_remote_address(request)

limiter = Limiter(key_func=get_real_ip)

# 더 엄격한 rate limiting
@app.post("/login")
@limiter.limit("3/minute")  # IP당 3회/분
@limiter.limit("10/hour")   # IP당 10회/시간
async def handle_login(request: Request, login: LoginRequest):
    # 사용자별 추가 제한
    user_key = f"user:{login.username}"
    if await is_user_rate_limited(user_key):
        raise HTTPException(
            status_code=429,
            detail="Too many login attempts. Please try again later."
        )
    # ...
```

---

### 2.5 CORS 기본값 강화

- **위치:** `auth-service/main.py:54`
- **심각도:** Critical
- **문제:** CORS 기본값이 `*`로 모든 origin 허용

**현재 코드:**
```python
ALLOWED_ORIGINS = os.getenv("ALLOWED_ORIGINS", "*").split(",")
```

**개선 코드:**
```python
def get_allowed_origins() -> list[str]:
    origins = os.getenv("ALLOWED_ORIGINS")
    if not origins:
        env = os.getenv("ENVIRONMENT", "development")
        if env == "production":
            raise ValueError("ALLOWED_ORIGINS must be set in production")
        return ["http://localhost:3000"]  # 개발 환경 기본값
    return [o.strip() for o in origins.split(",") if o.strip()]

ALLOWED_ORIGINS = get_allowed_origins()
```

---

### 2.6 입력 검증 강화

- **위치:** `auth-service/main.py:30-31`
- **심각도:** High
- **문제:** 사용자명/비밀번호 검증이 길이만 확인

**현재 코드:**
```python
class LoginRequest(BaseModel):
    username: str = Field(..., min_length=1, max_length=100)
    password: str = Field(..., min_length=1, max_length=200)
```

**개선 코드:**
```python
import re
from pydantic import field_validator

class LoginRequest(BaseModel):
    username: str = Field(..., min_length=3, max_length=100)
    password: str = Field(..., min_length=8, max_length=200)

    @field_validator('username')
    @classmethod
    def validate_username(cls, v: str) -> str:
        if not re.match(r'^[a-zA-Z0-9_-]+$', v):
            raise ValueError('Username must contain only alphanumeric, underscore, or hyphen')
        return v

    @field_validator('password')
    @classmethod
    def validate_password(cls, v: str) -> str:
        # 빈 공백만 있는 경우 방지
        if not v.strip():
            raise ValueError('Password cannot be only whitespace')
        return v
```

---

### 2.7 Authorization 헤더 파싱 개선

- **위치:** `auth-service/main.py:141-152`
- **심각도:** High
- **문제:** Bearer 토큰 파싱이 단순하여 injection 가능성

**현재 코드:**
```python
parts = auth_header.split(' ')
if len(parts) != 2:
    raise HTTPException(...)
token = parts[1]
```

**개선 코드:**
```python
import re

def extract_bearer_token(auth_header: str) -> str:
    """Authorization 헤더에서 Bearer 토큰 추출"""
    if not auth_header:
        raise HTTPException(
            status_code=401,
            detail="Authorization header is required"
        )

    # Bearer 토큰 형식 검증
    match = re.match(r'^Bearer\s+([A-Za-z0-9\-_\.]+)$', auth_header)
    if not match:
        raise HTTPException(
            status_code=401,
            detail="Invalid Authorization header format"
        )

    token = match.group(1)

    # 토큰 길이 제한 (JWT는 보통 수백 자)
    if len(token) > 2000:
        raise HTTPException(
            status_code=401,
            detail="Token too long"
        )

    return token
```

---

## 3. 성능 개선

### 3.1 ClientSession 관리 개선

- **위치:** `auth-service/auth_service.py:22-27`
- **심각도:** Medium
- **문제:** 매 요청마다 세션 상태 확인 오버헤드

**현재 코드:**
```python
@classmethod
async def get_session(cls) -> aiohttp.ClientSession:
    if cls._session is None or cls._session.closed:
        cls._session = aiohttp.ClientSession()
    return cls._session
```

**개선 코드:**
```python
import asyncio
from contextlib import asynccontextmanager

class AuthService:
    _session: Optional[aiohttp.ClientSession] = None
    _lock: asyncio.Lock = asyncio.Lock()

    @classmethod
    async def get_session(cls) -> aiohttp.ClientSession:
        if cls._session is None or cls._session.closed:
            async with cls._lock:
                if cls._session is None or cls._session.closed:
                    connector = aiohttp.TCPConnector(
                        limit=100,
                        limit_per_host=30,
                        keepalive_timeout=30
                    )
                    cls._session = aiohttp.ClientSession(
                        connector=connector,
                        timeout=aiohttp.ClientTimeout(total=10)
                    )
        return cls._session
```

---

### 3.2 상태 코드 그룹화 최적화

- **위치:** `auth-service/main.py:93-105`
- **심각도:** Low
- **문제:** 매 요청마다 if-elif 체인으로 상태 코드 분류

**현재 코드:**
```python
status_group = "unknown"
if 200 <= status_code < 300:
    status_group = "2xx"
elif 300 <= status_code < 400:
    status_group = "3xx"
# ...
```

**개선 코드:**
```python
def get_status_group(status_code: int) -> str:
    """HTTP 상태 코드를 그룹으로 변환"""
    if 100 <= status_code < 600:
        return f"{status_code // 100}xx"
    return "unknown"

# 사용
status_group = get_status_group(response.status_code)
```

---

## 4. 아키텍처 개선

### 4.1 의존성 주입 패턴

- **위치:** `auth-service/main.py:44-50`
- **심각도:** Medium
- **문제:** 전역 변수로 auth_service 관리

**현재 코드:**
```python
app = FastAPI(lifespan=lifespan)
auth_service = AuthService()
```

**개선 코드:**
```python
from fastapi import Depends

def get_auth_service() -> AuthService:
    return AuthService()

@app.post("/login")
async def handle_login(
    login: LoginRequest,
    auth_service: AuthService = Depends(get_auth_service)
):
    result = await auth_service.login(login.username, login.password)
    # ...
```

---

### 4.2 응답 모델 통일

- **위치:** `auth-service/auth_service.py:49-83`
- **심각도:** Medium
- **문제:** 응답 형식이 일관성 없음

**개선 코드:**
```python
from pydantic import BaseModel
from typing import Optional, Any

class AuthResponse(BaseModel):
    status: str  # "success" | "failed"
    message: Optional[str] = None
    data: Optional[dict] = None
    error_code: Optional[str] = None

# 사용
async def login(self, username: str, password: str) -> AuthResponse:
    try:
        user_data = await self._verify_user_from_service(username, password)
        if not user_data:
            return AuthResponse(
                status="failed",
                message="Invalid username or password",
                error_code="INVALID_CREDENTIALS"
            )

        token = self._create_token(user_data)
        return AuthResponse(
            status="success",
            data={"token": token}
        )
    except UserServiceError as e:
        return AuthResponse(
            status="failed",
            message="Authentication service temporarily unavailable",
            error_code="SERVICE_UNAVAILABLE"
        )
```

---

## 5. 모니터링/로깅 개선

### 5.1 구조화된 로깅

- **위치:** `auth-service/auth_service.py:55, 66`
- **심각도:** Medium
- **문제:** 로그에 사용자명이 평문으로 기록됨

**개선 코드:**
```python
import hashlib
from pythonjsonlogger import jsonlogger

def mask_username(username: str) -> str:
    """사용자명을 해시하여 마스킹"""
    return hashlib.sha256(username.encode()).hexdigest()[:8]

# 로깅 설정
handler = logging.StreamHandler()
formatter = jsonlogger.JsonFormatter()
handler.setFormatter(formatter)
logger.addHandler(handler)

# 사용
logger.warning("login_failed", extra={
    "user_hash": mask_username(username),
    "reason": "invalid_credentials"
})

logger.info("login_success", extra={
    "user_hash": mask_username(username),
    "token_jti": jwt_payload.get("jti")
})
```

---

### 5.2 비즈니스 메트릭 추가

- **위치:** `auth-service/main.py:87-124`
- **심각도:** Medium
- **문제:** HTTP 메트릭만 있고 비즈니스 메트릭 없음

**개선 코드:**
```python
from prometheus_client import Counter, Histogram

# 인증 관련 메트릭
auth_attempts_total = Counter(
    'auth_login_attempts_total',
    'Total login attempts',
    ['result']  # success, failed, rate_limited
)

auth_token_verifications_total = Counter(
    'auth_token_verifications_total',
    'Total token verification attempts',
    ['result']  # success, expired, invalid
)

user_service_requests_total = Counter(
    'auth_user_service_requests_total',
    'Requests to user service',
    ['status']  # success, timeout, error
)

user_service_latency = Histogram(
    'auth_user_service_latency_seconds',
    'User service request latency'
)

# 사용
@app.post("/login")
async def handle_login(login: LoginRequest):
    with user_service_latency.time():
        result = await auth_service.login(login.username, login.password)

    if result.status == "success":
        auth_attempts_total.labels(result="success").inc()
    else:
        auth_attempts_total.labels(result="failed").inc()

    return result
```

---

### 5.3 상관 ID 추가

- **위치:** `auth-service/main.py` 전체
- **심각도:** Medium
- **문제:** 분산 추적 불가

**개선 코드:**
```python
import uuid
from contextvars import ContextVar

request_id_var: ContextVar[str] = ContextVar('request_id', default='')

@app.middleware("http")
async def add_request_id(request: Request, call_next):
    request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    request_id_var.set(request_id)

    response = await call_next(request)
    response.headers["X-Request-ID"] = request_id

    return response

# 로깅에서 사용
class RequestIdFilter(logging.Filter):
    def filter(self, record):
        record.request_id = request_id_var.get('')
        return True

logger.addFilter(RequestIdFilter())
```

---

### 5.4 /stats 엔드포인트 개선

- **위치:** `auth-service/main.py:169`
- **심각도:** Low
- **문제:** `active_session_count`가 항상 0

**개선 코드:**
```python
# Redis를 사용한 세션 추적
import redis.asyncio as redis

class SessionTracker:
    def __init__(self, redis_url: str):
        self.redis = redis.from_url(redis_url)

    async def add_session(self, user_id: str, jti: str, ttl: int):
        await self.redis.setex(f"session:{jti}", ttl, user_id)
        await self.redis.sadd(f"user_sessions:{user_id}", jti)

    async def remove_session(self, jti: str):
        await self.redis.delete(f"session:{jti}")

    async def get_active_count(self) -> int:
        keys = await self.redis.keys("session:*")
        return len(keys)

@app.get("/stats")
async def handle_stats():
    return {
        "service": "auth-service",
        "status": "running",
        "active_session_count": await session_tracker.get_active_count(),
        "metrics": {
            "login_attempts": auth_attempts_total._metrics,
            "token_verifications": auth_token_verifications_total._metrics
        }
    }
```

---

## 수정 우선순위

1. **즉시 수정 (Critical)**
   - CORS 기본값 `*` 제거
   - JWT 필수 클레임 추가 (`iat`, `jti`)
   - Rate limit 강화 (로그인 3/분 이하)
   - 비밀 키 강도 검증 추가
   - RS256 알고리즘 검토

2. **1주 내 수정 (High)**
   - 네트워크 에러 처리 개선
   - 입력 검증 강화
   - Authorization 헤더 파싱 개선
   - 비즈니스 메트릭 추가

3. **2주 내 수정 (Medium)**
   - 구조화된 로깅 도입
   - 의존성 주입 패턴 적용
   - 응답 모델 통일
   - 상관 ID 추가
