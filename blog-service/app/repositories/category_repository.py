# blog-service/app/repositories/category_repository.py
import logging
import random
import re
from typing import Optional, List, Dict, Any
from app.repositories.base import BaseRepository
from app.config import USE_POSTGRES, DATABASE_PATH

logger = logging.getLogger(__name__)

if USE_POSTGRES:
    import asyncpg
else:
    import aiosqlite


def generate_random_color() -> str:
    """Generate random color for new categories."""
    colors = [
        '#EF4444',  # Red
        '#F97316',  # Orange
        '#EAB308',  # Yellow
        '#22C55E',  # Green
        '#14B8A6',  # Teal
        '#3B82F6',  # Blue
        '#8B5CF6',  # Purple
        '#EC4899',  # Pink
        '#6366F1',  # Indigo
        '#06B6D4',  # Cyan
    ]
    return random.choice(colors)


def generate_slug(name: str) -> str:
    """Convert category name to URL-safe slug."""
    slug = name.lower().strip()
    slug = re.sub(r'[^\w\s-]', '', slug)
    slug = re.sub(r'[\s_]+', '-', slug)
    slug = slug.strip('-')
    return slug


class CategoryRepository(BaseRepository[Dict]):
    """Repository for Category entity operations."""

    def __init__(self, pool: Optional[Any] = None):
        self.use_postgres = USE_POSTGRES
        self.pool = pool

    def set_pool(self, pool: Any) -> None:
        """Set the database connection pool (for PostgreSQL)."""
        self.pool = pool

    async def get_by_id(self, category_id: int) -> Optional[Dict]:
        """Fetch single category by ID."""
        if self.use_postgres:
            async with self.pool.acquire() as conn:
                row = await conn.fetchrow(
                    "SELECT id, name, slug, color FROM categories WHERE id = $1",
                    category_id
                )
                return dict(row) if row else None
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                conn.row_factory = aiosqlite.Row
                cursor = await conn.execute(
                    "SELECT id, name, slug, color FROM categories WHERE id = ?",
                    (category_id,)
                )
                row = await cursor.fetchone()
                return dict(row) if row else None

    async def get_by_name(self, name: str) -> Optional[Dict]:
        """Fetch single category by name."""
        if self.use_postgres:
            async with self.pool.acquire() as conn:
                row = await conn.fetchrow(
                    "SELECT id, name, slug, color FROM categories WHERE name = $1",
                    name
                )
                return dict(row) if row else None
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                conn.row_factory = aiosqlite.Row
                cursor = await conn.execute(
                    "SELECT id, name, slug, color FROM categories WHERE name = ?",
                    (name,)
                )
                row = await cursor.fetchone()
                return dict(row) if row else None

    async def get_all(
        self, offset: int = 0, limit: int = 100, **filters: Any
    ) -> List[Dict]:
        """Fetch all categories with post counts."""
        query = """
            SELECT c.id, c.name, c.slug, c.color, COUNT(p.id) as post_count
            FROM categories c
            LEFT JOIN posts p ON c.id = p.category_id
            GROUP BY c.id, c.name, c.slug, c.color
            ORDER BY c.id
        """

        if self.use_postgres:
            async with self.pool.acquire() as conn:
                rows = await conn.fetch(query)
                return [dict(row) for row in rows]
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                conn.row_factory = aiosqlite.Row
                cursor = await conn.execute(query)
                rows = await cursor.fetchall()
                return [dict(row) for row in rows]

    async def create(self, data: Dict[str, Any]) -> Dict:
        """Create a new category."""
        name = data["name"]
        slug = data.get("slug") or generate_slug(name)
        color = data.get("color") or generate_random_color()

        if self.use_postgres:
            async with self.pool.acquire() as conn:
                row = await conn.fetchrow(
                    "INSERT INTO categories (name, slug, color) VALUES ($1, $2, $3) RETURNING id, name, slug, color",
                    name, slug, color
                )
                return dict(row)
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                cursor = await conn.execute(
                    "INSERT INTO categories (name, slug, color) VALUES (?, ?, ?)",
                    (name, slug, color)
                )
                category_id = cursor.lastrowid
                await conn.commit()
                return {
                    "id": category_id,
                    "name": name,
                    "slug": slug,
                    "color": color
                }

    async def get_or_create(self, name: str) -> Dict:
        """Get existing category or create new one with random color."""
        existing = await self.get_by_name(name)
        if existing:
            return existing
        return await self.create({"name": name})

    async def update(
        self, category_id: int, data: Dict[str, Any]
    ) -> Optional[Dict]:
        """Update a category."""
        name = data.get("name")
        slug = data.get("slug")
        color = data.get("color")

        fields = []
        params = []
        param_idx = 1

        if self.use_postgres:
            if name is not None:
                fields.append(f"name = ${param_idx}")
                params.append(name)
                param_idx += 1
            if slug is not None:
                fields.append(f"slug = ${param_idx}")
                params.append(slug)
                param_idx += 1
            if color is not None:
                fields.append(f"color = ${param_idx}")
                params.append(color)
                param_idx += 1

            if not fields:
                return None

            params.append(category_id)
            query = f"UPDATE categories SET {', '.join(fields)} WHERE id = ${param_idx}"

            async with self.pool.acquire() as conn:
                await conn.execute(query, *params)
                return await self.get_by_id(category_id)
        else:
            if name is not None:
                fields.append("name = ?")
                params.append(name)
            if slug is not None:
                fields.append("slug = ?")
                params.append(slug)
            if color is not None:
                fields.append("color = ?")
                params.append(color)

            if not fields:
                return None

            params.append(category_id)
            query = f"UPDATE categories SET {', '.join(fields)} WHERE id = ?"

            async with aiosqlite.connect(DATABASE_PATH) as conn:
                await conn.execute(query, tuple(params))
                await conn.commit()
                return await self.get_by_id(category_id)

    async def delete(self, category_id: int) -> bool:
        """Delete a category."""
        if self.use_postgres:
            async with self.pool.acquire() as conn:
                result = await conn.execute("DELETE FROM categories WHERE id = $1", category_id)
                return result != "DELETE 0"
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                cursor = await conn.execute("DELETE FROM categories WHERE id = ?", (category_id,))
                await conn.commit()
                return cursor.rowcount > 0

    async def cleanup_empty(self) -> int:
        """Delete categories with no posts. Returns number of deleted categories."""
        if self.use_postgres:
            async with self.pool.acquire() as conn:
                result = await conn.execute('''
                    DELETE FROM categories
                    WHERE id NOT IN (SELECT DISTINCT category_id FROM posts)
                ''')
                deleted_count = int(result.split()[-1]) if result and result.startswith('DELETE') else 0
                return deleted_count
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                cursor = await conn.execute('''
                    DELETE FROM categories
                    WHERE id NOT IN (SELECT DISTINCT category_id FROM posts)
                ''')
                await conn.commit()
                return cursor.rowcount

    async def count(self, **filters: Any) -> int:
        """Get total number of categories."""
        if self.use_postgres:
            async with self.pool.acquire() as conn:
                count = await conn.fetchval("SELECT COUNT(*) FROM categories")
                return count or 0
        else:
            async with aiosqlite.connect(DATABASE_PATH) as conn:
                cursor = await conn.execute("SELECT COUNT(*) FROM categories")
                row = await cursor.fetchone()
                return row[0] if row else 0
