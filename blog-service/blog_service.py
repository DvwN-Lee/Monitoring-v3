import os
import logging
from typing import Optional
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, HTTPException, Depends, Query, Response
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator
from prometheus_client import Counter
from prometheus_fastapi_instrumentator.metrics import Info

try:
    from prometheus_fastapi_instrumentator.metrics import request_latency
except ImportError:
    from prometheus_fastapi_instrumentator import metrics as _metrics

    def request_latency(*args, **kwargs):
        return _metrics.latency(*args, **kwargs)

# Import from app modules
from app.config import REQUEST_LATENCY_BUCKETS
from app.auth import require_user, AuthClient
from app.models.schemas import PostCreate, PostUpdate
from app.database import db
from app.cache import cache

# --- 기본 로깅 ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger('BlogServiceApp')

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize and cleanup resources."""
    # Startup
    await db.initialize()
    await cache.initialize()
    logger.info("Blog service initialized: database and cache ready")
    yield
    # Shutdown
    await db.close()
    await cache.close()
    await AuthClient.close()
    logger.info("Blog service shutdown: database, cache, and AuthClient closed")

app = FastAPI(lifespan=lifespan)

# CORS 설정
# Environment-based CORS configuration
ALLOWED_ORIGINS = os.getenv("ALLOWED_ORIGINS", "*").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization", "X-Requested-With"],
)

# Prometheus 메트릭 설정
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

# --- 정적 파일 및 템플릿 설정 ---
templates = Jinja2Templates(directory="templates")
app.mount("/blog/static", StaticFiles(directory="static"), name="static")

# --- API 핸들러 함수 ---
@app.get("/blog/api/posts")
async def handle_get_posts(
    offset: int = Query(0, ge=0),
    limit: int = Query(20, ge=1, le=100),
    category: Optional[str] = Query(None)
):
    """모든 블로그 게시물 목록을 반환합니다(최신순, 페이지네이션, 카테고리 필터링)."""
    # Calculate page number for caching
    page = offset // limit if limit > 0 else 0

    # 1. Check cache
    cached = await cache.get_posts(page, limit, category)
    if cached:
        return JSONResponse(content=cached)

    # 2. Query database
    try:
        items = await db.get_posts(offset, limit, category)
    except Exception as e:
        logger.error(f"Database error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Database error: {str(e)}")

    # 3. Format response - 목록 응답은 요약 정보 위주로 반환 + 발췌(excerpt) + 카테고리 정보
    summaries = []
    for p in items:
        content = (p.get("content") or "").replace("\r", " ").replace("\n", " ")
        excerpt = content[:120] + ("..." if len(content) > 120 else "")
        summaries.append({
            "id": p["id"],
            "title": p["title"],
            "author": p["author"],
            "created_at": p["created_at"].isoformat() if hasattr(p["created_at"], 'isoformat') else str(p["created_at"]),
            "excerpt": excerpt,
            "category": {
                "id": p["category_id"],
                "name": p["category_name"],
                "slug": p["category_slug"]
            }
        })

    # 4. Store in cache
    await cache.set_posts(page, limit, summaries, category, ttl=60)

    return JSONResponse(content=summaries)

@app.get("/blog/api/posts/{post_id}")
async def handle_get_post_by_id(post_id: int):
    """ID로 특정 게시물을 찾아 반환합니다."""
    # 1. Check cache
    cached = await cache.get_post(post_id)
    if cached:
        return JSONResponse(content=cached)

    # 2. Query database
    try:
        post_dict = await db.get_post_by_id(post_id)
    except Exception as e:
        logger.error(f"Database error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail="Database error")

    if not post_dict:
        raise HTTPException(status_code=404, detail={'error': 'Post not found'})

    # 3. Format response with category info
    response = {
        "id": post_dict["id"],
        "title": post_dict["title"],
        "content": post_dict["content"],
        "author": post_dict["author"],
        "created_at": post_dict["created_at"].isoformat() if hasattr(post_dict["created_at"], 'isoformat') else str(post_dict["created_at"]),
        "updated_at": post_dict["updated_at"].isoformat() if hasattr(post_dict["updated_at"], 'isoformat') else str(post_dict["updated_at"]),
        "category": {
            "id": post_dict["category_id"],
            "name": post_dict["category_name"],
            "slug": post_dict["category_slug"]
        }
    }

    # 4. Store in cache
    await cache.set_post(post_id, response, ttl=300)

    return JSONResponse(content=response)

@app.post("/blog/api/posts", status_code=201)
async def create_post(request: Request, payload: PostCreate, username: str = Depends(require_user)):
    try:
        # Get or create category
        category = await db.get_or_create_category(payload.category_name)
        category_id = category['id']

        # Create post
        new_post = await db.create_post(payload.title, payload.content, username, category_id)

        # Invalidate cache
        await cache.invalidate_posts()

        return JSONResponse(content=new_post, status_code=201)
    except Exception as e:
        logger.error(f"Database error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Database error: {str(e)}")

@app.patch("/blog/api/posts/{post_id}")
async def update_post_partial(post_id: int, request: Request, payload: PostUpdate, username: str = Depends(require_user)):
    try:
        # Check author
        author = await db.get_post_author(post_id)
        if not author:
            raise HTTPException(status_code=404, detail={'error': 'Post not found'})
        if author != username:
            raise HTTPException(status_code=403, detail='Forbidden: not the author')

        # Get or create category if provided
        category_id = None
        if payload.category_name is not None:
            category = await db.get_or_create_category(payload.category_name)
            category_id = category['id']

        # Update post
        updated_post = await db.update_post(post_id, payload.title, payload.content, category_id)
        if not updated_post:
             return JSONResponse(content={"message": "No changes"})

        # Invalidate cache
        await cache.invalidate_posts()

        # Format response
        response = {
            "id": updated_post["id"],
            "title": updated_post["title"],
            "content": updated_post["content"],
            "author": updated_post["author"],
            "created_at": updated_post["created_at"].isoformat() if hasattr(updated_post["created_at"], 'isoformat') else str(updated_post["created_at"]),
            "updated_at": updated_post["updated_at"].isoformat() if hasattr(updated_post["updated_at"], 'isoformat') else str(updated_post["updated_at"]),
            "category": {
                "id": updated_post["category_id"],
                "name": updated_post["category_name"],
                "slug": updated_post["category_slug"]
            }
        }
        return JSONResponse(content=response)

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Database error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Database error: {str(e)}")

@app.get("/blog/api/categories")
async def handle_get_categories():
    """모든 카테고리 목록과 각 카테고리별 게시물 수를 반환합니다."""
    # 1. Check cache
    cached = await cache.get_categories()
    if cached:
        return JSONResponse(content=cached)

    # 2. Query database
    try:
        categories = await db.get_categories_with_counts()
    except Exception as e:
        logger.error(f"Database error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail="Database error")

    # 3. Store in cache
    await cache.set_categories(categories, ttl=600)

    return JSONResponse(content=categories)

@app.delete("/blog/api/posts/{post_id}", status_code=204)
async def delete_post(post_id: int, request: Request, username: str = Depends(require_user)):
    try:
        # Fetch post to check author
        post = await db.get_post_by_id(post_id)
        if not post:
            raise HTTPException(status_code=404, detail={'error': 'Post not found'})
        if post['author'] != username:
            raise HTTPException(status_code=403, detail='Forbidden: not the author')

        # Delete post
        await db.delete_post(post_id)

        # Cleanup empty categories
        deleted_count = await db.cleanup_empty_categories()
        if deleted_count > 0:
            logger.info(f"Deleted {deleted_count} empty categories")

        # Invalidate cache
        await cache.invalidate_posts()

        return Response(status_code=204)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Database error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Database error: {str(e)}")

@app.get("/health")
async def handle_health():
    """Kubernetes를 위한 헬스 체크 엔드포인트"""
    return {"status": "ok", "service": "blog-service"}

@app.get("/stats")
async def handle_stats():
    """대시보드를 위한 통계 엔드포인트"""
    try:
        post_count = await db.get_post_count()
    except Exception as e:
        logger.error(f"Failed to get post count: {e}", exc_info=True)
        post_count = 0

    return {
        "blog_service": {
            "service_status": "online",
            "post_count": post_count
        }
    }

# --- 웹 페이지 서빙 (SPA) ---
@app.get("/")
async def serve_root(request: Request):
    """루트 경로에서 블로그 페이지를 렌더링합니다."""
    return templates.TemplateResponse("index.html", {"request": request})

@app.get("/blog/")
async def serve_blog_root(request: Request):
    """블로그 루트 경로에서 블로그 페이지를 렌더링합니다."""
    return templates.TemplateResponse("index.html", {"request": request})

@app.get("/blog/{path:path}")
async def serve_spa(request: Request, path: str):
    """블로그 서브 경로에서 블로그 페이지를 렌더링합니다."""
    return templates.TemplateResponse("index.html", {"request": request})

if __name__ == "__main__":
    import uvicorn
    port = 8005
    logger.info(f"Blog Service starting on http://0.0.0.0:{port}")
    uvicorn.run(app, host="0.0.0.0", port=port)
