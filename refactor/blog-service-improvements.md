# Blog Service 코드 리뷰 개선사항

## 요약

| 심각도 | 개수 |
|--------|------|
| Critical | 4 |
| High | 8 |
| Medium | 8 |

---

## 1. 코드 품질 개선

### 1.1 Token 파싱 에러 미처리

- **위치:** `blog-service/app/auth.py:35`
- **심각도:** High
- **문제:** Authorization 헤더에서 토큰 추출 시 IndexError 발생 가능

**현재 코드:**
```python
token = auth_header.split(' ')[1]
```

**개선 코드:**
```python
import re

def extract_bearer_token(auth_header: str) -> str:
    if not auth_header:
        raise HTTPException(status_code=401, detail='Authorization header required')

    match = re.match(r'^Bearer\s+([A-Za-z0-9\-_\.]+)$', auth_header)
    if not match:
        raise HTTPException(status_code=401, detail='Invalid Authorization header format')

    return match.group(1)

# 사용
token = extract_bearer_token(auth_header)
```

---

### 1.2 aiohttp 요청 타임아웃 미설정

- **위치:** `blog-service/app/auth.py:40-43`
- **심각도:** High
- **문제:** auth-service가 응답하지 않으면 무한 대기

**현재 코드:**
```python
async with session.get(verify_url, headers=headers) as resp:
```

**개선 코드:**
```python
import aiohttp

timeout = aiohttp.ClientTimeout(total=5)
async with session.get(verify_url, headers=headers, timeout=timeout) as resp:
    if resp.status != 200:
        logger.warning(f"Auth service returned {resp.status}")
        raise HTTPException(status_code=401, detail='Authentication failed')

    try:
        data = await resp.json()
    except (aiohttp.ContentTypeError, json.JSONDecodeError):
        raise HTTPException(status_code=502, detail='Invalid auth service response')
```

---

### 1.3 데이터베이스 에러 메시지 노출

- **위치:** `blog-service/blog_service.py:127, 206, 252`
- **심각도:** Critical
- **문제:** 내부 데이터베이스 에러를 클라이언트에 노출

**현재 코드:**
```python
except Exception as e:
    raise HTTPException(status_code=500, detail=f"Database error: {str(e)}")
```

**개선 코드:**
```python
import uuid

except Exception as e:
    error_id = str(uuid.uuid4())[:8]
    logger.error(f"Database error [{error_id}]: {e}", exc_info=True)
    raise HTTPException(
        status_code=500,
        detail=f"Internal server error. Reference: {error_id}"
    )
```

---

### 1.4 하드코딩된 매직 넘버

- **위치:** `blog-service/blog_service.py:133, 148, 186`
- **심각도:** Medium
- **문제:** TTL, 문자열 길이 등이 코드에 직접 삽입

**개선 코드:**
```python
# app/config.py에 상수 정의
class BlogConfig:
    EXCERPT_LENGTH = 120
    POSTS_LIST_CACHE_TTL = 60
    POST_DETAIL_CACHE_TTL = 300
    CATEGORIES_CACHE_TTL = 600
    POSTS_PER_PAGE_DEFAULT = 20
    POSTS_PER_PAGE_MAX = 100

# 사용
from app.config import BlogConfig

excerpt = content[:BlogConfig.EXCERPT_LENGTH] + "..." if len(content) > BlogConfig.EXCERPT_LENGTH else content
await cache.set_posts(page, limit, category, items, ttl=BlogConfig.POSTS_LIST_CACHE_TTL)
```

---

### 1.5 응답 포매팅 중복

- **위치:** `blog-service/blog_service.py:130-145, 171-183, 232-245`
- **심각도:** Medium
- **문제:** post 응답을 dict로 변환하는 코드가 3곳에 반복

**개선 코드:**
```python
# utils.py
def format_post_response(post: dict, include_content: bool = True) -> dict:
    """Post dictionary를 API 응답 형식으로 변환"""
    response = {
        "id": post["id"],
        "title": post["title"],
        "author": post["author"],
        "created_at": format_datetime(post.get("created_at")),
        "updated_at": format_datetime(post.get("updated_at")),
        "category": {
            "id": post.get("category_id"),
            "name": post.get("category_name"),
            "slug": post.get("category_slug")
        }
    }

    if include_content:
        response["content"] = post.get("content", "")
    else:
        content = post.get("content", "")
        response["excerpt"] = content[:120] + "..." if len(content) > 120 else content

    return response

def format_datetime(dt) -> str:
    if dt is None:
        return None
    if hasattr(dt, 'isoformat'):
        return dt.isoformat()
    return str(dt)
```

---

### 1.6 미사용 models.py

- **위치:** `blog-service/models.py:1-45`
- **심각도:** Low
- **문제:** SQLAlchemy 모델이 정의되어 있지만 사용되지 않음

**개선 제안:**
- 옵션 1: 파일 삭제 (현재 raw SQL 사용)
- 옵션 2: SQLAlchemy ORM으로 완전 마이그레이션 (권장)

---

## 2. 보안 개선

### 2.1 Race Condition in Author Check

- **위치:** `blog-service/blog_service.py:212-216, 278-282`
- **심각도:** Critical
- **문제:** PATCH/DELETE 시 author 확인과 실제 작업 사이에 race condition 가능

**현재 코드:**
```python
existing_post = await db.get_post_by_id(post_id)
if existing_post["author"] != username:
    raise HTTPException(status_code=403, detail="Not authorized")
# 여기서 다른 요청이 게시물을 삭제할 수 있음
updated = await db.update_post(post_id, ...)
```

**개선 코드:**
```python
# database.py
async def update_post_if_author(
    self,
    post_id: int,
    author: str,
    title: Optional[str],
    content: Optional[str],
    category_name: Optional[str]
) -> Optional[dict]:
    """작성자 확인과 업데이트를 원자적으로 수행"""
    if self.use_postgres:
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                # 락을 걸고 조회
                row = await conn.fetchrow(
                    "SELECT * FROM posts WHERE id = $1 AND author = $2 FOR UPDATE",
                    post_id, author
                )
                if not row:
                    return None

                # 업데이트 수행
                await conn.execute(
                    "UPDATE posts SET title = COALESCE($1, title), ... WHERE id = $3",
                    title, content, post_id
                )
                return await conn.fetchrow("SELECT * FROM posts WHERE id = $1", post_id)

# blog_service.py
updated = await db.update_post_if_author(post_id, username, title, content, category_name)
if updated is None:
    # 게시물이 없거나 권한 없음
    existing = await db.get_post_by_id(post_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Post not found")
    raise HTTPException(status_code=403, detail="Not authorized")
```

---

### 2.2 Content Sanitization 부재 (XSS)

- **위치:** `blog-service/blog_service.py:132-133`
- **심각도:** Critical
- **문제:** 게시물 content를 그대로 반환하여 XSS 공격 가능

**개선 코드:**
```python
import bleach

ALLOWED_TAGS = ['p', 'br', 'strong', 'em', 'u', 'a', 'ul', 'ol', 'li', 'code', 'pre']
ALLOWED_ATTRIBUTES = {'a': ['href', 'title']}

def sanitize_html(content: str) -> str:
    """HTML 컨텐츠를 안전하게 필터링"""
    return bleach.clean(
        content,
        tags=ALLOWED_TAGS,
        attributes=ALLOWED_ATTRIBUTES,
        strip=True
    )

# 저장 시 sanitize
async def create_post(post: PostCreate, username: str):
    sanitized_content = sanitize_html(post.content)
    post_id = await db.create_post(
        title=sanitize_html(post.title),
        content=sanitized_content,
        author=username,
        category_name=post.category_name
    )
```

---

### 2.3 입력 검증 강화

- **위치:** `blog-service/app/models/schemas.py:7-9`
- **심각도:** High
- **문제:** Title/Content 공백 검증 미흡

**현재 코드:**
```python
class PostCreate(BaseModel):
    title: str = Field(..., min_length=1, max_length=200)
    content: str = Field(..., min_length=1)
    category_name: str = Field(..., max_length=50)
```

**개선 코드:**
```python
import re
from pydantic import field_validator

class PostCreate(BaseModel):
    title: str = Field(..., min_length=1, max_length=200)
    content: str = Field(..., min_length=1, max_length=100000)
    category_name: str = Field(..., min_length=1, max_length=50)

    @field_validator('title', 'content', mode='before')
    @classmethod
    def strip_whitespace(cls, v: str) -> str:
        return v.strip() if isinstance(v, str) else v

    @field_validator('title', 'content')
    @classmethod
    def check_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError('Cannot be only whitespace')
        return v

    @field_validator('category_name')
    @classmethod
    def validate_category(cls, v: str) -> str:
        if not re.match(r'^[\w\s\-]+$', v):
            raise ValueError('Category name contains invalid characters')
        return v.strip()
```

---

### 2.4 Offset/Limit 검증 강화

- **위치:** `blog-service/blog_service.py:108-110`
- **심각도:** Medium
- **문제:** 매우 큰 offset 값으로 성능 문제 유발 가능

**현재 코드:**
```python
offset: int = Query(0, ge=0),
limit: int = Query(20, ge=1, le=100),
```

**개선 코드:**
```python
MAX_OFFSET = 10000

offset: int = Query(0, ge=0, le=MAX_OFFSET, description="Offset for pagination (max 10000)"),
limit: int = Query(20, ge=1, le=100, description="Number of items per page"),

# 또는 cursor-based pagination으로 변경
@app.get("/blog/api/posts")
async def handle_get_posts(
    cursor: Optional[int] = Query(None, description="Last post ID for cursor-based pagination"),
    limit: int = Query(20, ge=1, le=100)
):
    if cursor:
        items = await db.get_posts_after_cursor(cursor, limit)
    else:
        items = await db.get_posts(0, limit)
```

---

### 2.5 CORS 설정 강화

- **위치:** `blog-service/blog_service.py:51`
- **심각도:** Critical
- **문제:** CORS 기본값이 `*`

**개선 코드:**
```python
def get_allowed_origins() -> list[str]:
    origins = os.getenv("ALLOWED_ORIGINS")
    if not origins:
        env = os.getenv("ENVIRONMENT", "development")
        if env == "production":
            raise ValueError("ALLOWED_ORIGINS must be set in production")
        return ["http://localhost:3000"]
    return [o.strip() for o in origins.split(",") if o.strip()]
```

---

## 3. 성능 개선

### 3.1 캐시 무효화 전략 개선

- **위치:** `blog-service/blog_service.py:201, 230, 293`
- **심각도:** High
- **문제:** 모든 posts 캐시를 삭제하여 비효율적

**현재 코드:**
```python
await cache.invalidate_posts()  # 모든 posts* 캐시 삭제
```

**개선 코드:**
```python
# cache.py
class BlogCache:
    async def invalidate_post(self, post_id: int):
        """특정 게시물 캐시 무효화"""
        await self.redis_client.delete(f"post:{post_id}")

    async def invalidate_posts_list(self, category_slug: Optional[str] = None):
        """게시물 목록 캐시 무효화"""
        if category_slug:
            # 특정 카테고리만
            pattern = f"posts:*:category:{category_slug}"
        else:
            # 전체 목록
            pattern = "posts:*"

        async for key in self.redis_client.scan_iter(pattern):
            await self.redis_client.delete(key)

    async def invalidate_categories(self):
        """카테고리 캐시 무효화"""
        await self.redis_client.delete("categories:list")

# 사용
await cache.invalidate_post(post_id)
await cache.invalidate_posts_list(category_slug=post.category_slug)
await cache.invalidate_categories()  # 새 카테고리 생성 시
```

---

### 3.2 카테고리 캐시 무효화 추가

- **위치:** `blog-service/blog_service.py:201, 230`
- **심각도:** Medium
- **문제:** 새 게시물 생성 시 categories 캐시 미갱신

**개선 코드:**
```python
@app.post("/blog/api/posts", status_code=201)
async def handle_create_post(post: PostCreate, user: dict = Depends(get_current_user)):
    # 게시물 생성
    result = await db.create_post(...)

    # 캐시 무효화
    await cache.invalidate_posts_list()

    # 새 카테고리가 생성되었을 수 있으므로 카테고리 캐시도 무효화
    if result.get("new_category"):
        await cache.invalidate_categories()

    return result
```

---

### 3.3 인덱스 추가 (SQLite)

- **위치:** `blog-service/app/database.py:115-117, 159`
- **심각도:** High
- **문제:** SQLite에서 인덱스 부족으로 쿼리 성능 저하

**개선 코드:**
```python
# SQLite 스키마 초기화
async def initialize_sqlite(self):
    async with aiosqlite.connect(self.db_file) as conn:
        await conn.execute('''
            CREATE TABLE IF NOT EXISTS posts (...)
        ''')

        # 인덱스 추가
        await conn.execute('''
            CREATE INDEX IF NOT EXISTS idx_posts_author ON posts(author)
        ''')
        await conn.execute('''
            CREATE INDEX IF NOT EXISTS idx_posts_created_at ON posts(created_at DESC)
        ''')
        await conn.execute('''
            CREATE INDEX IF NOT EXISTS idx_posts_category_id ON posts(category_id)
        ''')

        await conn.commit()
```

---

### 3.4 Cache Hit Rate 모니터링

- **위치:** `blog-service/app/cache.py:40-42, 67-69`
- **심각도:** Medium
- **문제:** 캐시 히트/미스가 Prometheus 메트릭으로 기록되지 않음

**개선 코드:**
```python
from prometheus_client import Counter

cache_hits = Counter(
    'blog_cache_hits_total',
    'Total cache hits',
    ['key_type']  # posts, post, categories
)

cache_misses = Counter(
    'blog_cache_misses_total',
    'Total cache misses',
    ['key_type']
)

async def get_posts(self, page: int, limit: int, category: Optional[str]) -> Optional[list]:
    cache_key = f"posts:{page}:{limit}:{category or 'all'}"
    data = await self.redis_client.get(cache_key)

    if data:
        cache_hits.labels(key_type='posts').inc()
        return json.loads(data)

    cache_misses.labels(key_type='posts').inc()
    return None
```

---

### 3.5 cleanup_empty_categories 최적화

- **위치:** `blog-service/app/database.py:218-236`
- **심각도:** Low
- **문제:** 게시물 삭제마다 empty category cleanup 실행

**개선 코드:**
```python
# 더 효율적인 쿼리
async def cleanup_empty_categories(self):
    """사용되지 않는 카테고리 삭제 (기본 카테고리 제외)"""
    query = """
        DELETE FROM categories
        WHERE id NOT IN (
            SELECT DISTINCT category_id FROM posts WHERE category_id IS NOT NULL
        )
        AND id > 3
    """
    # 또는 배치로 주기적 실행
```

---

## 4. 아키텍처 개선

### 4.1 SQLAlchemy ORM 마이그레이션 권장

- **위치:** `blog-service/app/database.py` 전체
- **심각도:** Medium
- **문제:** Raw SQL로 PostgreSQL/SQLite 코드 중복

**개선 코드:**
```python
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy import select, update, delete

class BlogRepository:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def get_posts(
        self,
        offset: int,
        limit: int,
        category_slug: Optional[str] = None
    ) -> list[Post]:
        query = (
            select(Post)
            .join(Category)
            .options(selectinload(Post.category))
            .order_by(Post.created_at.desc())
            .offset(offset)
            .limit(limit)
        )

        if category_slug:
            query = query.where(Category.slug == category_slug)

        result = await self.session.execute(query)
        return result.scalars().all()

    async def update_post_if_author(
        self,
        post_id: int,
        author: str,
        **updates
    ) -> Optional[Post]:
        async with self.session.begin():
            # 락과 함께 조회
            query = (
                select(Post)
                .where(Post.id == post_id, Post.author == author)
                .with_for_update()
            )
            result = await self.session.execute(query)
            post = result.scalar_one_or_none()

            if not post:
                return None

            for key, value in updates.items():
                if value is not None:
                    setattr(post, key, value)

            return post
```

---

### 4.2 Response Model 정의

- **위치:** `blog-service/blog_service.py` 전체
- **심각도:** Medium
- **문제:** JSONResponse를 직접 반환하여 스키마 검증 없음

**개선 코드:**
```python
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime

class CategoryResponse(BaseModel):
    id: int
    name: str
    slug: str

class PostResponse(BaseModel):
    id: int
    title: str
    content: str
    author: str
    created_at: datetime
    updated_at: Optional[datetime]
    category: CategoryResponse

class PostListResponse(BaseModel):
    id: int
    title: str
    excerpt: str
    author: str
    created_at: datetime
    category: CategoryResponse

class PaginatedPostsResponse(BaseModel):
    items: List[PostListResponse]
    total: int
    page: int
    limit: int

@app.get("/blog/api/posts", response_model=PaginatedPostsResponse)
async def handle_get_posts(...):
    # ...
    return PaginatedPostsResponse(items=items, total=total, page=page, limit=limit)

@app.get("/blog/api/posts/{post_id}", response_model=PostResponse)
async def handle_get_post_by_id(post_id: int):
    # ...
```

---

### 4.3 의존성 주입 강화

- **위치:** `blog-service/blog_service.py` 전체
- **심각도:** Medium
- **문제:** db, cache가 전역 singleton으로 관리

**개선 코드:**
```python
from fastapi import Depends

async def get_db() -> BlogDatabase:
    return db

async def get_cache() -> BlogCache:
    return cache

async def get_current_user(
    authorization: str = Header(...),
    auth_client: AuthClient = Depends(get_auth_client)
) -> dict:
    token = extract_bearer_token(authorization)
    return await auth_client.verify(token)

@app.get("/blog/api/posts/{post_id}")
async def handle_get_post_by_id(
    post_id: int,
    db: BlogDatabase = Depends(get_db),
    cache: BlogCache = Depends(get_cache)
):
    # 캐시 확인
    cached = await cache.get_post(post_id)
    if cached:
        return cached

    # DB 조회
    post = await db.get_post_by_id(post_id)
    if not post:
        raise HTTPException(status_code=404, detail="Post not found")

    await cache.set_post(post_id, post)
    return post
```

---

## 5. 모니터링/로깅 개선

### 5.1 구조화된 로깅

- **위치:** `blog-service/blog_service.py:30`
- **심각도:** Medium
- **문제:** 문자열 기반 로깅으로 파싱 어려움

**개선 코드:**
```python
from pythonjsonlogger import jsonlogger

def setup_logging():
    handler = logging.StreamHandler()
    formatter = jsonlogger.JsonFormatter(
        '%(asctime)s %(levelname)s %(name)s %(message)s'
    )
    handler.setFormatter(formatter)
    logging.root.addHandler(handler)
    logging.root.setLevel(os.getenv('LOG_LEVEL', 'INFO'))

# 사용
logger.info("post_created", extra={
    "post_id": post_id,
    "author": username,
    "category": category_name
})
```

---

### 5.2 비즈니스 메트릭 추가

- **위치:** `blog-service/blog_service.py:63-81`
- **심각도:** Medium
- **문제:** HTTP 메트릭만 있고 비즈니스 메트릭 없음

**개선 코드:**
```python
from prometheus_client import Counter, Gauge

# 비즈니스 메트릭
posts_created_total = Counter(
    'blog_posts_created_total',
    'Total posts created'
)

posts_deleted_total = Counter(
    'blog_posts_deleted_total',
    'Total posts deleted'
)

posts_updated_total = Counter(
    'blog_posts_updated_total',
    'Total posts updated'
)

auth_failures_total = Counter(
    'blog_auth_failures_total',
    'Total authentication failures'
)

active_categories = Gauge(
    'blog_categories_active',
    'Number of active categories'
)

# 사용
@app.post("/blog/api/posts", status_code=201)
async def handle_create_post(...):
    result = await db.create_post(...)
    posts_created_total.inc()
    return result
```

---

### 5.3 에러 메트릭 추가

- **위치:** `blog-service/blog_service.py:125-127, 204-206`
- **심각도:** Low
- **문제:** 데이터베이스 에러 발생 시 메트릭 미기록

**개선 코드:**
```python
from prometheus_client import Counter

db_errors_total = Counter(
    'blog_db_errors_total',
    'Database errors',
    ['operation', 'error_type']
)

@app.get("/blog/api/posts")
async def handle_get_posts(...):
    try:
        items = await db.get_posts(offset, limit, category)
    except Exception as e:
        db_errors_total.labels(
            operation='get_posts',
            error_type=type(e).__name__
        ).inc()
        raise

    return items
```

---

### 5.4 성능 로깅 추가

- **위치:** `blog-service/blog_service.py` 전체
- **심각도:** Low
- **문제:** 데이터베이스/캐시 조회 시간 로깅 없음

**개선 코드:**
```python
import time
from prometheus_client import Histogram

db_query_duration = Histogram(
    'blog_db_query_duration_seconds',
    'Database query duration',
    ['operation']
)

cache_operation_duration = Histogram(
    'blog_cache_operation_duration_seconds',
    'Cache operation duration',
    ['operation']
)

@app.get("/blog/api/posts")
async def handle_get_posts(...):
    # 캐시 조회
    with cache_operation_duration.labels(operation='get_posts').time():
        cached = await cache.get_posts(page, limit, category)

    if cached:
        return cached

    # DB 조회
    with db_query_duration.labels(operation='get_posts').time():
        items = await db.get_posts(offset, limit, category)

    return items
```

---

### 5.5 API 버전 관리

- **위치:** `blog-service/blog_service.py:107-338`
- **심각도:** Low
- **문제:** API 경로에 버전이 없음

**개선 코드:**
```python
from fastapi import APIRouter

router_v1 = APIRouter(prefix="/blog/api/v1", tags=["v1"])

@router_v1.get("/posts")
async def handle_get_posts_v1(...):
    # ...

app.include_router(router_v1)

# 기존 경로는 deprecated로 유지 (호환성)
@app.get("/blog/api/posts", deprecated=True)
async def handle_get_posts_legacy(...):
    # v1으로 리다이렉트 또는 동일 로직
```

---

## 수정 우선순위

1. **즉시 수정 (Critical)**
   - XSS 방지 (Content sanitization)
   - Race condition 해결 (원자적 쿼리)
   - 데이터베이스 에러 메시지 숨김
   - CORS 기본값 강화

2. **1주 내 수정 (High)**
   - Token 파싱 에러 처리
   - aiohttp 타임아웃 설정
   - 입력 검증 강화
   - 캐시 무효화 전략 개선
   - SQLite 인덱스 추가

3. **2주 내 수정 (Medium)**
   - 구조화된 로깅 도입
   - Response Model 정의
   - 의존성 주입 강화
   - 비즈니스 메트릭 추가
   - 코드 중복 제거 (응답 포매팅)

4. **장기 개선**
   - SQLAlchemy ORM 마이그레이션
   - API 버전 관리 도입
   - Cursor-based pagination
