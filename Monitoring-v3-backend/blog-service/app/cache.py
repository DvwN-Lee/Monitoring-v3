# blog-service/app/cache.py
import redis.asyncio as redis
import json
import logging
from typing import Optional
from app.config import REDIS_URL

logger = logging.getLogger(__name__)


class BlogCache:
    def __init__(self):
        try:
            self.redis_client = redis.from_url(REDIS_URL, decode_responses=True)
            logger.info(f"Blog cache service initialized and connected to Redis at {REDIS_URL}")
        except Exception as e:
            logger.error(f"Failed to connect to Redis: {e}")
            self.redis_client = None

    async def initialize(self):
        """Verify Redis connection on startup."""
        if self.redis_client:
            try:
                is_connected = await self.redis_client.ping()
                if is_connected:
                    logger.info("Redis connection verified successfully")
                else:
                    logger.warning("Redis connection verification failed")
            except Exception as e:
                logger.warning(f"Redis ping failed: {e}")

    async def get_posts(self, page: int, limit: int, category_slug: Optional[str] = None) -> Optional[dict]:
        """Get cached posts list."""
        if not self.redis_client:
            return None
        try:
            key = f"posts:list:page:{page}:limit:{limit}:cat:{category_slug}"
            data = await self.redis_client.get(key)
            if data:
                logger.info(f"Cache HIT for posts list (page={page}, limit={limit}, category={category_slug})")
                return json.loads(data)
            logger.info(f"Cache MISS for posts list (page={page}, limit={limit}, category={category_slug})")
            return None
        except Exception as e:
            logger.error(f"Redis GET error for posts list: {e}")
            return None

    async def set_posts(self, page: int, limit: int, data: dict, category_slug: Optional[str] = None, ttl: int = 60):
        """Cache posts list with 60s TTL."""
        if not self.redis_client:
            return
        try:
            key = f"posts:list:page:{page}:limit:{limit}:cat:{category_slug}"
            await self.redis_client.setex(key, ttl, json.dumps(data, default=str))
            logger.info(f"Cached posts list (page={page}, limit={limit}, category={category_slug}) with {ttl}s TTL")
        except Exception as e:
            logger.error(f"Redis SET error for posts list: {e}")

    async def get_post(self, post_id: int) -> Optional[dict]:
        """Get cached single post."""
        if not self.redis_client:
            return None
        try:
            key = f"post:{post_id}"
            data = await self.redis_client.get(key)
            if data:
                logger.info(f"Cache HIT for post ID {post_id}")
                return json.loads(data)
            logger.info(f"Cache MISS for post ID {post_id}")
            return None
        except Exception as e:
            logger.error(f"Redis GET error for post {post_id}: {e}")
            return None

    async def set_post(self, post_id: int, data: dict, ttl: int = 300):
        """Cache single post with 300s TTL."""
        if not self.redis_client:
            return
        try:
            key = f"post:{post_id}"
            await self.redis_client.setex(key, ttl, json.dumps(data, default=str))
            logger.info(f"Cached post ID {post_id} with {ttl}s TTL")
        except Exception as e:
            logger.error(f"Redis SET error for post {post_id}: {e}")

    async def get_categories(self) -> Optional[list]:
        """Get cached categories list."""
        if not self.redis_client:
            return None
        try:
            data = await self.redis_client.get("categories:list")
            if data:
                logger.info("Cache HIT for categories list")
                return json.loads(data)
            logger.info("Cache MISS for categories list")
            return None
        except Exception as e:
            logger.error(f"Redis GET error for categories: {e}")
            return None

    async def set_categories(self, data: list, ttl: int = 600):
        """Cache categories list with 600s TTL."""
        if not self.redis_client:
            return
        try:
            await self.redis_client.setex("categories:list", ttl, json.dumps(data, default=str))
            logger.info(f"Cached categories list with {ttl}s TTL")
        except Exception as e:
            logger.error(f"Redis SET error for categories: {e}")

    async def invalidate_posts(self):
        """Invalidate all posts cache when post is created/updated/deleted."""
        if not self.redis_client:
            return
        try:
            keys = []
            async for key in self.redis_client.scan_iter("post*"):
                keys.append(key)

            if keys:
                await self.redis_client.delete(*keys)
                logger.info(f"Invalidated {len(keys)} post cache entries")
        except Exception as e:
            logger.error(f"Redis cache invalidation error: {e}")

    async def close(self):
        """Close Redis connection."""
        if self.redis_client:
            await self.redis_client.close()
            logger.info("Redis connection closed")


# Singleton instance
cache = BlogCache()
