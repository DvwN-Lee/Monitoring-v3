# blog-service/app/repositories/post_repository.py
import logging
from typing import Optional, List, Dict, Any
from datetime import datetime
from app.repositories.base import BaseRepository
from app.config import USE_POSTGRES, DB_CONFIG, DATABASE_PATH

logger = logging.getLogger(__name__)

if USE_POSTGRES:
    import asyncpg
else:
    import aiosqlite


class PostRepository(BaseRepository[Dict]):
    """Repository for Post entity operations."""

    def __init__(self, pool: Optional[Any] = None):
        self.use_postgres = USE_POSTGRES
        self.pool = pool

    def set_pool(self, pool: Any) -> None:
        """Set the database connection pool (for PostgreSQL)."""
        self.pool = pool

    async def get_by_id(self, post_id: int) -> Optional[Dict]:
        """Fetch single post by ID with category info."""
        query = """
            SELECT p.id, p.title, p.content, p.author, p.created_at, p.updated_at, p.category_id,
                   c.name as category_name, c.slug as category_slug
            FROM posts p
            INNER JOIN categories c ON p.category_id = c.id
            WHERE p.id = """

        if self.use_postgres:
            query += "$1"
            async with self.pool.acquire() as conn:
                row = await conn.fetchrow(query, post_id)
                return dict(row) if row else None
        else:
            query += "?"
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                conn.row_factory = aiosqlite.Row
                cursor = await conn.execute(query, (post_id,))
                row = await cursor.fetchone()
                return dict(row) if row else None

    async def get_all(
        self, offset: int = 0, limit: int = 20, **filters: Any
    ) -> List[Dict]:
        """Fetch paginated posts with category info, ordered by id DESC."""
        category_slug = filters.get("category_slug")
        base_query = """
            SELECT p.id, p.title, p.content, p.author, p.created_at, p.updated_at, p.category_id,
                   c.name as category_name, c.slug as category_slug
            FROM posts p
            INNER JOIN categories c ON p.category_id = c.id
        """

        if self.use_postgres:
            if category_slug:
                query = base_query + " WHERE c.slug = $1 ORDER BY p.id DESC LIMIT $2 OFFSET $3"
                async with self.pool.acquire() as conn:
                    rows = await conn.fetch(query, category_slug, limit, offset)
                    return [dict(row) for row in rows]
            else:
                query = base_query + " ORDER BY p.id DESC LIMIT $1 OFFSET $2"
                async with self.pool.acquire() as conn:
                    rows = await conn.fetch(query, limit, offset)
                    return [dict(row) for row in rows]
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                conn.row_factory = aiosqlite.Row
                if category_slug:
                    query = base_query + " WHERE c.slug = ? ORDER BY p.id DESC LIMIT ? OFFSET ?"
                    cursor = await conn.execute(query, (category_slug, limit, offset))
                else:
                    query = base_query + " ORDER BY p.id DESC LIMIT ? OFFSET ?"
                    cursor = await conn.execute(query, (limit, offset))
                rows = await cursor.fetchall()
                return [dict(row) for row in rows]

    async def create(self, data: Dict[str, Any]) -> Dict:
        """Create a new post and return it with category info."""
        title = data["title"]
        content = data["content"]
        author = data["author"]
        category_id = data["category_id"]

        if self.use_postgres:
            async with self.pool.acquire() as conn:
                async with conn.transaction():
                    row = await conn.fetchrow(
                        "INSERT INTO posts (title, content, author, category_id) VALUES ($1, $2, $3, $4) RETURNING id, created_at, updated_at",
                        title, content, author, category_id
                    )
                    post_id = row["id"]
                    created_at = row["created_at"].isoformat() if row["created_at"] else None
                    updated_at = row["updated_at"].isoformat() if row["updated_at"] else None

                    cat = await conn.fetchrow("SELECT name, slug FROM categories WHERE id = $1", category_id)
                    category_name = cat["name"] if cat else None
                    category_slug = cat["slug"] if cat else None
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                conn.row_factory = aiosqlite.Row
                now = datetime.utcnow().isoformat()
                cursor = await conn.execute(
                    "INSERT INTO posts (title, content, author, category_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                    (title, content, author, category_id, now, now)
                )
                post_id = cursor.lastrowid
                created_at = now
                updated_at = now
                await conn.commit()

                cursor = await conn.execute("SELECT name, slug FROM categories WHERE id = ?", (category_id,))
                cat = await cursor.fetchone()
                category_name = cat["name"] if cat else None
                category_slug = cat["slug"] if cat else None

        return {
            "id": post_id,
            "title": title,
            "content": content,
            "author": author,
            "created_at": created_at,
            "updated_at": updated_at,
            "category": {
                "id": category_id,
                "name": category_name,
                "slug": category_slug
            }
        }

    async def update(
        self, post_id: int, data: Dict[str, Any]
    ) -> Optional[Dict]:
        """Update a post (no author check)."""
        title = data.get("title")
        content = data.get("content")
        category_id = data.get("category_id")

        fields = []
        params = []
        param_idx = 1

        if self.use_postgres:
            if title is not None:
                fields.append(f"title = ${param_idx}")
                params.append(title)
                param_idx += 1
            if content is not None:
                fields.append(f"content = ${param_idx}")
                params.append(content)
                param_idx += 1
            if category_id is not None:
                fields.append(f"category_id = ${param_idx}")
                params.append(category_id)
                param_idx += 1

            if not fields:
                return None

            fields.append("updated_at = CURRENT_TIMESTAMP")
            params.append(post_id)

            query = f"UPDATE posts SET {', '.join(fields)} WHERE id = ${param_idx}"

            async with self.pool.acquire() as conn:
                await conn.execute(query, *params)
                return await self.get_by_id(post_id)
        else:
            if title is not None:
                fields.append("title = ?")
                params.append(title)
            if content is not None:
                fields.append("content = ?")
                params.append(content)
            if category_id is not None:
                fields.append("category_id = ?")
                params.append(category_id)

            if not fields:
                return None

            fields.append("updated_at = ?")
            params.append(datetime.utcnow().isoformat())
            params.append(post_id)

            query = f"UPDATE posts SET {', '.join(fields)} WHERE id = ?"

            async with aiosqlite.connect(DATABASE_PATH) as conn:
                await conn.execute(query, tuple(params))
                await conn.commit()
                return await self.get_by_id(post_id)

    async def update_atomic(
        self, post_id: int, author: str, data: Dict[str, Any]
    ) -> Optional[Dict]:
        """Atomic update with author check."""
        title = data.get("title")
        content = data.get("content")
        category_id = data.get("category_id")

        fields = []
        params = []
        param_idx = 1

        if self.use_postgres:
            if title is not None:
                fields.append(f"title = ${param_idx}")
                params.append(title)
                param_idx += 1
            if content is not None:
                fields.append(f"content = ${param_idx}")
                params.append(content)
                param_idx += 1
            if category_id is not None:
                fields.append(f"category_id = ${param_idx}")
                params.append(category_id)
                param_idx += 1

            if not fields:
                return "no_changes"

            fields.append("updated_at = CURRENT_TIMESTAMP")
            params.extend([post_id, author])

            query = f"""
                UPDATE posts SET {', '.join(fields)}
                WHERE id = ${param_idx} AND author = ${param_idx + 1}
                RETURNING id
            """

            async with self.pool.acquire() as conn:
                result = await conn.fetchval(query, *params)
                if result is None:
                    return None
                return await self.get_by_id(post_id)
        else:
            if title is not None:
                fields.append("title = ?")
                params.append(title)
            if content is not None:
                fields.append("content = ?")
                params.append(content)
            if category_id is not None:
                fields.append("category_id = ?")
                params.append(category_id)

            if not fields:
                return "no_changes"

            fields.append("updated_at = ?")
            params.append(datetime.utcnow().isoformat())
            params.extend([post_id, author])

            query = f"UPDATE posts SET {', '.join(fields)} WHERE id = ? AND author = ?"

            async with aiosqlite.connect(DATABASE_PATH) as conn:
                cursor = await conn.execute(query, tuple(params))
                await conn.commit()
                if cursor.rowcount == 0:
                    return None
                return await self.get_by_id(post_id)

    async def delete(self, post_id: int) -> bool:
        """Delete a post."""
        if self.use_postgres:
            async with self.pool.acquire() as conn:
                result = await conn.execute("DELETE FROM posts WHERE id = $1", post_id)
                return result != "DELETE 0"
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                cursor = await conn.execute("DELETE FROM posts WHERE id = ?", (post_id,))
                await conn.commit()
                return cursor.rowcount > 0

    async def delete_atomic(self, post_id: int, author: str) -> bool:
        """Atomic delete with author check."""
        if self.use_postgres:
            async with self.pool.acquire() as conn:
                result = await conn.execute(
                    "DELETE FROM posts WHERE id = $1 AND author = $2",
                    post_id, author
                )
                return result != "DELETE 0"
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                cursor = await conn.execute(
                    "DELETE FROM posts WHERE id = ? AND author = ?",
                    (post_id, author)
                )
                await conn.commit()
                return cursor.rowcount > 0

    async def count(self, **filters: Any) -> int:
        """Get total number of posts."""
        if self.use_postgres:
            async with self.pool.acquire() as conn:
                count = await conn.fetchval("SELECT COUNT(*) FROM posts")
                return count or 0
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                cursor = await conn.execute("SELECT COUNT(*) FROM posts")
                row = await cursor.fetchone()
                return row[0] if row else 0

    async def get_author(self, post_id: int) -> Optional[str]:
        """Get the author of a post for permission checking."""
        if self.use_postgres:
            async with self.pool.acquire() as conn:
                return await conn.fetchval("SELECT author FROM posts WHERE id = $1", post_id)
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                cursor = await conn.execute("SELECT author FROM posts WHERE id = ?", (post_id,))
                row = await cursor.fetchone()
                return row[0] if row else None
