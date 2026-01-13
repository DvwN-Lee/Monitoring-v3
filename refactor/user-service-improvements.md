# User Service 코드 리뷰 개선사항

## 요약

| 심각도 | 개수 |
|--------|------|
| Critical | 6 |
| High | 4 |
| Medium | 5 |

---

## 1. 코드 품질 개선

### 1.1 에러 처리의 과도한 일반화

- **위치:** `user-service/cache_service.py:38-40`
- **심각도:** Medium
- **문제:** 모든 예외를 동일하게 처리하여 문제 원인 구분 불가

**현재 코드:**
```python
except Exception as e:
    logger.error(f"Redis GET error for user ID {user_id}: {e}")
    return None
```

**개선 코드:**
```python
import asyncio
import json

async def get_user(self, user_id: str) -> Optional[dict]:
    if not self.redis_client:
        return None

    try:
        user_data = await asyncio.wait_for(
            self.redis_client.get(f"user:{user_id}"),
            timeout=1.0
        )
        if user_data:
            return json.loads(user_data)
        return None

    except asyncio.TimeoutError:
        logger.warning(f"Redis timeout for user {user_id}")
        return None
    except json.JSONDecodeError as e:
        logger.error(f"Invalid JSON in cache for user {user_id}: {e}")
        await self.redis_client.delete(f"user:{user_id}")  # 잘못된 데이터 삭제
        return None
    except redis.RedisError as e:
        logger.error(f"Redis error for user {user_id}: {e}")
        return None
```

---

### 1.2 미사용 Pydantic 모델

- **위치:** `user-service/user_service.py:26-29`
- **심각도:** Low
- **문제:** `UserOut` 모델이 정의되어 있지만 일관되게 사용되지 않음

**개선 코드:**
```python
class UserOut(BaseModel):
    id: int
    username: str
    email: EmailStr

    class Config:
        from_attributes = True

# 엔드포인트에서 일관되게 사용
@app.post("/users", response_model=UserOut, status_code=201)
async def create_user(user: UserIn):
    user_id = await db.add_user(user.username, user.email, user.password)
    if user_id is None:
        raise HTTPException(status_code=400, detail="Username already exists")
    created_user = await db.get_user_by_id(user_id)
    return UserOut(**created_user)

@app.get("/users/{username}", response_model=UserOut)
async def get_user(username: str):
    # ...
    return UserOut(**user)
```

---

### 1.3 생성된 사용자 조회 에러 처리 누락

- **위치:** `user-service/user_service.py:146-152`
- **심각도:** High
- **문제:** `db.get_user_by_id(user_id)`가 None을 반환할 수 있음에도 에러 처리 없음

**현재 코드:**
```python
user_id = await db.add_user(user.username, user.email, user.password)
if user_id is None:
    raise HTTPException(status_code=400, detail="Username already exists")
created_user = await db.get_user_by_id(user_id)
return created_user
```

**개선 코드:**
```python
user_id = await db.add_user(user.username, user.email, user.password)
if user_id is None:
    raise HTTPException(status_code=400, detail="Username already exists")

created_user = await db.get_user_by_id(user_id)
if not created_user:
    logger.error(f"Failed to retrieve newly created user with ID {user_id}")
    raise HTTPException(status_code=500, detail="Failed to retrieve created user")

# 캐시에 저장
await cache.set_user(created_user["username"], created_user)

return UserOut(**created_user)
```

---

### 1.4 불필요한 코드 중복 (PostgreSQL/SQLite)

- **위치:** `user-service/database_service.py:142-186`
- **심각도:** Medium
- **문제:** PostgreSQL과 SQLite 코드가 거의 동일하게 반복됨

**개선 코드:**
```python
from abc import ABC, abstractmethod

class DatabaseInterface(ABC):
    @abstractmethod
    async def get_user_by_username(self, username: str) -> Optional[dict]:
        pass

    @abstractmethod
    async def add_user(self, username: str, email: str, password: str) -> Optional[int]:
        pass

class PostgreSQLDatabase(DatabaseInterface):
    async def get_user_by_username(self, username: str) -> Optional[dict]:
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT id, username, email FROM users WHERE username = $1",
                username
            )
            return dict(row) if row else None

class SQLiteDatabase(DatabaseInterface):
    async def get_user_by_username(self, username: str) -> Optional[dict]:
        async with aiosqlite.connect(self.db_file) as conn:
            conn.row_factory = aiosqlite.Row
            cursor = await conn.execute(
                "SELECT id, username, email FROM users WHERE username = ?",
                (username,)
            )
            row = await cursor.fetchone()
            return dict(row) if row else None

def create_database(use_postgres: bool) -> DatabaseInterface:
    if use_postgres:
        return PostgreSQLDatabase()
    return SQLiteDatabase()
```

---

### 1.5 캐시 키 명명 불일치

- **위치:** `user-service/cache_service.py:28-50` 및 `user-service/user_service.py:156`
- **심각도:** Medium
- **문제:** 메서드명은 `get_user(user_id)`인데 실제로는 username을 전달

**개선 코드:**
```python
# cache_service.py
async def get_user_by_username(self, username: str) -> Optional[dict]:
    """username으로 사용자 캐시 조회"""
    cache_key = f"user:username:{username}"
    # ...

async def set_user_by_username(self, username: str, user_data: dict, ttl: int = 300):
    """username으로 사용자 캐시 저장"""
    cache_key = f"user:username:{username}"
    # password_hash 제외
    safe_data = {k: v for k, v in user_data.items() if k != 'password_hash'}
    # ...

async def invalidate_user(self, username: str):
    """사용자 캐시 무효화"""
    await self.redis_client.delete(f"user:username:{username}")
```

---

## 2. 보안 개선

### 2.1 패스워드 입력 검증 부족

- **위치:** `user-service/user_service.py:21-24`
- **심각도:** Critical
- **문제:** 비밀번호에 대한 길이, 복잡도 검증이 없음

**현재 코드:**
```python
class UserIn(BaseModel):
    username: str
    email: EmailStr
    password: str
```

**개선 코드:**
```python
import re
from pydantic import field_validator

class UserIn(BaseModel):
    username: str = Field(..., min_length=3, max_length=100)
    email: EmailStr
    password: str = Field(..., min_length=8, max_length=128)

    @field_validator('username')
    @classmethod
    def validate_username(cls, v: str) -> str:
        if not re.match(r'^[a-zA-Z0-9_-]+$', v):
            raise ValueError('Username must contain only alphanumeric, underscore, or hyphen')
        return v

    @field_validator('password')
    @classmethod
    def validate_password(cls, v: str) -> str:
        if not any(c.isupper() for c in v):
            raise ValueError('Password must contain at least one uppercase letter')
        if not any(c.islower() for c in v):
            raise ValueError('Password must contain at least one lowercase letter')
        if not any(c.isdigit() for c in v):
            raise ValueError('Password must contain at least one digit')
        return v
```

---

### 2.2 암호 저장 알고리즘 강화

- **위치:** `user-service/database_service.py:111`
- **심각도:** Critical
- **문제:** PBKDF2는 권장사항보다 낮은 수준의 보안 제공

**현재 코드:**
```python
password_hash = generate_password_hash(password, method='pbkdf2:sha256:60000')
```

**개선 코드:**
```python
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

ph = PasswordHasher(
    time_cost=3,
    memory_cost=65536,
    parallelism=4,
    hash_len=32,
    salt_len=16
)

async def add_user(self, username: str, email: str, password: str) -> Optional[int]:
    password_hash = ph.hash(password)
    # ...

async def verify_user_credentials(self, username: str, password: str) -> Optional[dict]:
    user = await self.get_user_by_username(username)
    if not user:
        return None

    try:
        ph.verify(user['password_hash'], password)
        # 필요시 rehash
        if ph.check_needs_rehash(user['password_hash']):
            new_hash = ph.hash(password)
            await self.update_password_hash(user['id'], new_hash)
        return user
    except VerifyMismatchError:
        return None
```

---

### 2.3 민감 정보 로깅

- **위치:** `user-service/database_service.py:65`
- **심각도:** High
- **문제:** 데이터베이스 호스트와 포트가 로그에 기록됨

**현재 코드:**
```python
logger.info(f"PostgreSQL connection pool created: {self.db_config['host']}:{self.db_config['port']}")
```

**개선 코드:**
```python
logger.info("PostgreSQL connection pool created successfully")
logger.debug(f"Database connection details", extra={
    "host_hash": hashlib.sha256(self.db_config['host'].encode()).hexdigest()[:8]
})
```

---

### 2.4 내부 API 인증 부재

- **위치:** `user-service/user_service.py` 전체
- **심각도:** Critical
- **문제:** `/users/verify-credentials` 엔드포인트가 누구나 호출 가능

**개선 코드:**
```python
import os
from fastapi import Header, Depends

INTERNAL_API_SECRET = os.getenv("INTERNAL_API_SECRET")

async def verify_internal_request(
    x_internal_secret: str = Header(..., alias="X-Internal-Secret")
) -> bool:
    if not INTERNAL_API_SECRET:
        raise HTTPException(status_code=500, detail="Internal API not configured")
    if x_internal_secret != INTERNAL_API_SECRET:
        raise HTTPException(status_code=403, detail="Forbidden")
    return True

@app.post("/users/verify-credentials")
async def verify_credentials(
    creds: Credentials,
    _: bool = Depends(verify_internal_request)
):
    user = await db.verify_user_credentials(creds.username, creds.password)
    if not user:
        raise HTTPException(status_code=401, detail="Invalid credentials")
    return {"id": user["id"], "username": user["username"], "email": user["email"]}
```

---

### 2.5 에러 메시지 정보 노출

- **위치:** `user-service/cache_service.py:39, 52, 61`
- **심각도:** Medium
- **문제:** 예외 메시지가 로그에 기록되어 내부 구현 노출 가능

**개선 코드:**
```python
async def get_user(self, username: str) -> Optional[dict]:
    try:
        user_data = await self.redis_client.get(f"user:username:{username}")
        if user_data:
            return json.loads(user_data)
        return None
    except Exception:
        logger.error(f"Redis operation failed for user lookup", extra={
            "operation": "get",
            "key_type": "user"
        })
        # 상세 에러는 debug 레벨로
        logger.debug(f"Redis error details", exc_info=True)
        return None
```

---

## 3. 성능 개선

### 3.1 캐시 일관성 문제

- **위치:** `user-service/user_service.py:146-152`
- **심각도:** High
- **문제:** 사용자 생성 후 캐시를 업데이트하지 않음

**개선 코드:**
```python
@app.post("/users", response_model=UserOut, status_code=201)
async def create_user(user: UserIn):
    user_id = await db.add_user(user.username, user.email, user.password)
    if user_id is None:
        raise HTTPException(status_code=400, detail="Username already exists")

    created_user = await db.get_user_by_id(user_id)
    if not created_user:
        raise HTTPException(status_code=500, detail="Failed to retrieve created user")

    # 캐시에 새 사용자 저장
    await cache.set_user_by_username(user.username, created_user)

    return UserOut(**created_user)
```

---

### 3.2 연속적 데이터베이스 조회 최적화

- **위치:** `user-service/user_service.py:146-152`
- **심각도:** Medium
- **문제:** INSERT 후 SELECT로 불필요한 왕복

**개선 코드:**
```python
# database_service.py에 추가
async def add_user_and_return(self, username: str, email: str, password: str) -> Optional[dict]:
    """사용자를 생성하고 생성된 정보를 반환"""
    password_hash = self.ph.hash(password)

    if self.use_postgres:
        async with self.pool.acquire() as conn:
            try:
                row = await conn.fetchrow(
                    """
                    INSERT INTO users (username, email, password_hash)
                    VALUES ($1, $2, $3)
                    RETURNING id, username, email
                    """,
                    username, email, password_hash
                )
                return dict(row) if row else None
            except asyncpg.UniqueViolationError:
                return None
    else:
        # SQLite는 RETURNING 지원하지 않으므로 기존 방식 유지
        # ...
```

---

### 3.3 데이터베이스 연결 풀 환경변수화

- **위치:** `user-service/database_service.py:60-64`
- **심각도:** Medium
- **문제:** 연결 풀 크기가 하드코딩

**현재 코드:**
```python
self.pool = await asyncpg.create_pool(
    min_size=5,
    max_size=20,
    **self.db_config
)
```

**개선 코드:**
```python
self.pool = await asyncpg.create_pool(
    min_size=int(os.getenv('DB_POOL_MIN_SIZE', '5')),
    max_size=int(os.getenv('DB_POOL_MAX_SIZE', '20')),
    command_timeout=float(os.getenv('DB_COMMAND_TIMEOUT', '30')),
    **self.db_config
)
```

---

### 3.4 캐시 히트율 추적

- **위치:** `user-service/cache_service.py:28-40`
- **심각도:** Low
- **문제:** 캐시 히트/미스 통계가 없음

**개선 코드:**
```python
from prometheus_client import Counter

cache_operations = Counter(
    'user_service_cache_operations_total',
    'Cache operations',
    ['operation', 'result']  # get/set, hit/miss/error
)

class CacheService:
    async def get_user_by_username(self, username: str) -> Optional[dict]:
        if not self.redis_client:
            cache_operations.labels(operation='get', result='skip').inc()
            return None

        try:
            user_data = await self.redis_client.get(f"user:username:{username}")
            if user_data:
                cache_operations.labels(operation='get', result='hit').inc()
                return json.loads(user_data)
            cache_operations.labels(operation='get', result='miss').inc()
            return None
        except Exception:
            cache_operations.labels(operation='get', result='error').inc()
            return None
```

---

## 4. 아키텍처 개선

### 4.1 의존성 주입 패턴

- **위치:** `user-service/user_service.py:35-37`
- **심각도:** Medium
- **문제:** 전역 변수로 객체 관리

**개선 코드:**
```python
from fastapi import Depends
from functools import lru_cache

class Settings:
    def __init__(self):
        self.database_url = os.getenv("DATABASE_URL")
        self.redis_url = os.getenv("REDIS_URL")
        self.use_postgres = os.getenv("USE_POSTGRES", "false").lower() == "true"

@lru_cache()
def get_settings() -> Settings:
    return Settings()

async def get_db(settings: Settings = Depends(get_settings)) -> UserServiceDatabase:
    db = UserServiceDatabase(use_postgres=settings.use_postgres)
    await db.initialize()
    return db

async def get_cache(settings: Settings = Depends(get_settings)) -> CacheService:
    cache = CacheService(redis_url=settings.redis_url)
    await cache.initialize()
    return cache

@app.post("/users", response_model=UserOut, status_code=201)
async def create_user(
    user: UserIn,
    db: UserServiceDatabase = Depends(get_db),
    cache: CacheService = Depends(get_cache)
):
    # ...
```

---

### 4.2 예외 처리 표준화

- **위치:** 전반적
- **심각도:** Medium
- **문제:** 예외 처리 방식이 일관되지 않음

**개선 코드:**
```python
# exceptions.py
class UserServiceError(Exception):
    """기본 사용자 서비스 예외"""
    pass

class UserNotFoundError(UserServiceError):
    """사용자를 찾을 수 없음"""
    pass

class UserAlreadyExistsError(UserServiceError):
    """사용자가 이미 존재"""
    pass

class DatabaseError(UserServiceError):
    """데이터베이스 오류"""
    pass

class CacheError(UserServiceError):
    """캐시 오류"""
    pass

# user_service.py에서 글로벌 핸들러
@app.exception_handler(UserNotFoundError)
async def user_not_found_handler(request: Request, exc: UserNotFoundError):
    return JSONResponse(
        status_code=404,
        content={"error": "Not Found", "message": "User not found"}
    )

@app.exception_handler(UserAlreadyExistsError)
async def user_exists_handler(request: Request, exc: UserAlreadyExistsError):
    return JSONResponse(
        status_code=409,
        content={"error": "Conflict", "message": "User already exists"}
    )

@app.exception_handler(DatabaseError)
async def database_error_handler(request: Request, exc: DatabaseError):
    logger.error(f"Database error: {exc}")
    return JSONResponse(
        status_code=500,
        content={"error": "Internal Server Error", "message": "Database error occurred"}
    )
```

---

### 4.3 단일 책임 원칙 적용

- **위치:** `user-service/database_service.py:1-50`
- **심각도:** Low
- **문제:** `UserServiceDatabase` 클래스가 너무 많은 역할 담당

**개선 코드:**
```
user-service/
├── config.py                  # 설정 관리
├── models.py                  # Pydantic 모델
├── exceptions.py              # 커스텀 예외
├── db/
│   ├── __init__.py
│   ├── interface.py           # 추상 인터페이스
│   ├── postgres.py            # PostgreSQL 구현
│   └── sqlite.py              # SQLite 구현
├── cache/
│   ├── __init__.py
│   └── redis.py               # Redis 캐시
├── services/
│   ├── __init__.py
│   └── user_service.py        # 비즈니스 로직
└── main.py                    # FastAPI 앱
```

---

## 5. 모니터링/로깅 개선

### 5.1 구조화된 로깅

- **위치:** 전반적
- **심각도:** Medium
- **문제:** 문자열 포맷팅 기반 로깅으로 파싱 어려움

**개선 코드:**
```python
from pythonjsonlogger import jsonlogger

def setup_logging():
    logger = logging.getLogger()
    handler = logging.StreamHandler()
    formatter = jsonlogger.JsonFormatter(
        '%(asctime)s %(levelname)s %(name)s %(message)s'
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    logger.setLevel(os.getenv('LOG_LEVEL', 'INFO'))
    return logger

# 사용
logger.info("user_created", extra={
    "user_id": user_id,
    "username_hash": hashlib.sha256(username.encode()).hexdigest()[:8]
})
```

---

### 5.2 /stats 엔드포인트 개선

- **위치:** `user-service/user_service.py:135`
- **심각도:** Low
- **문제:** 캐시 히트율이 하드코딩 (항상 0)

**개선 코드:**
```python
@app.get("/stats")
async def handle_stats():
    db_status = await db.health_check()
    cache_status = await cache.ping()

    # Prometheus 메트릭에서 히트율 계산
    cache_total = cache_operations.labels(operation='get', result='hit')._value.get() + \
                  cache_operations.labels(operation='get', result='miss')._value.get()
    cache_hits = cache_operations.labels(operation='get', result='hit')._value.get()
    hit_ratio = cache_hits / cache_total if cache_total > 0 else 0

    return {
        "service": "user-service",
        "status": "healthy" if db_status and cache_status else "degraded",
        "database": {
            "status": "connected" if db_status else "disconnected",
            "type": "postgresql" if db.use_postgres else "sqlite"
        },
        "cache": {
            "status": "connected" if cache_status else "disconnected",
            "hit_ratio": round(hit_ratio, 4)
        }
    }
```

---

### 5.3 헬스 체크 분리

- **위치:** `user-service/user_service.py:142-144`
- **심각도:** Medium
- **문제:** 의존성 상태를 확인하지 않음

**개선 코드:**
```python
@app.get("/health/live")
async def liveness():
    """Kubernetes liveness probe"""
    return {"status": "alive"}

@app.get("/health/ready")
async def readiness():
    """Kubernetes readiness probe"""
    db_ok = await db.health_check()
    cache_ok = await cache.ping()

    if not db_ok:
        raise HTTPException(status_code=503, detail="Database not ready")

    # 캐시는 선택적 (없어도 서비스 가능)
    return {
        "status": "ready",
        "database": "connected",
        "cache": "connected" if cache_ok else "disconnected"
    }
```

---

### 5.4 요청 로깅 미들웨어

- **위치:** 전반적
- **심각도:** Low
- **문제:** 요청/응답 로깅이 없음

**개선 코드:**
```python
import time
import uuid

@app.middleware("http")
async def log_requests(request: Request, call_next):
    request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    start_time = time.time()

    response = await call_next(request)

    process_time = time.time() - start_time

    # 민감한 경로는 상세 로깅 제외
    if "/verify-credentials" not in request.url.path:
        logger.info("http_request", extra={
            "request_id": request_id,
            "method": request.method,
            "path": request.url.path,
            "status_code": response.status_code,
            "process_time": round(process_time, 4)
        })

    response.headers["X-Request-ID"] = request_id
    response.headers["X-Process-Time"] = str(process_time)

    return response
```

---

## 수정 우선순위

1. **즉시 수정 (Critical)**
   - 입력 검증 강화 (비밀번호 복잡도)
   - Argon2 암호 알고리즘으로 변경
   - 내부 API 인증 추가
   - 생성된 사용자 조회 에러 처리

2. **1주 내 수정 (High)**
   - 캐시 일관성 문제 해결
   - 민감 정보 로깅 제거
   - 데이터베이스 추상화 계층 구현

3. **2주 내 수정 (Medium)**
   - 구조화된 로깅 도입
   - 의존성 주입 패턴 적용
   - 예외 처리 표준화
   - 캐시 히트율 추적
   - 헬스 체크 개선
