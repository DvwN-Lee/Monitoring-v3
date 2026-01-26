# blog-service/app/database.py
import os
import logging
from typing import Optional, Dict, List
from datetime import datetime
from app.config import USE_POSTGRES, DB_CONFIG, DATABASE_PATH
from app.repositories import PostRepository, CategoryRepository

logger = logging.getLogger(__name__)

if USE_POSTGRES:
    import asyncpg
    logger.info("Using PostgreSQL database with asyncpg")
else:
    import aiosqlite
    logger.info("Using SQLite database")


class BlogDatabase:
    """Database facade that delegates to Repository classes."""

    def __init__(self):
        self.use_postgres = USE_POSTGRES
        self.pool: Optional[asyncpg.Pool] = None
        self._initialized = False
        # Repository instances
        self._post_repo = PostRepository()
        self._category_repo = CategoryRepository()

    @property
    def posts(self) -> PostRepository:
        """Access to PostRepository."""
        return self._post_repo

    @property
    def categories(self) -> CategoryRepository:
        """Access to CategoryRepository."""
        return self._category_repo

    async def initialize(self):
        """Initialize database connection pool and schema."""
        if self._initialized:
            return

        if self.use_postgres:
            try:
                self.pool = await asyncpg.create_pool(
                    min_size=2,
                    max_size=20,
                    timeout=30,
                    command_timeout=10,
                    **DB_CONFIG
                )
                logger.info(f"PostgreSQL connection pool created: {DB_CONFIG['host']}:{DB_CONFIG['port']}")
                # Inject pool to repositories
                self._post_repo.set_pool(self.pool)
                self._category_repo.set_pool(self.pool)
                await self._initialize_postgres_schema()
            except Exception as e:
                logger.error(f"PostgreSQL pool creation failed: {e}", exc_info=True)
                raise
        else:
            await self._initialize_sqlite_schema()

        self._initialized = True

    async def _initialize_postgres_schema(self):
        """Initialize PostgreSQL database schema."""
        async with self.pool.acquire() as conn:
            # Create categories table
            await conn.execute('''
                CREATE TABLE IF NOT EXISTS categories (
                    id SERIAL PRIMARY KEY,
                    name VARCHAR(50) NOT NULL UNIQUE,
                    slug VARCHAR(50) NOT NULL UNIQUE,
                    color VARCHAR(7) DEFAULT '#6B7280'
                )
            ''')

            # Insert default categories if not exist
            count = await conn.fetchval("SELECT COUNT(*) FROM categories")
            if count == 0:
                await conn.execute('''
                    INSERT INTO categories (id, name, slug, color) VALUES
                    (1, '기술 스택', 'tech-stack', '#3B82F6'),
                    (2, 'Troubleshooting', 'troubleshooting', '#E9754A'),
                    (3, 'Test', 'test', '#757575')
                ''')

            # Synchronize categories_id_seq with existing data
            await conn.execute(
                "SELECT setval('categories_id_seq', COALESCE((SELECT MAX(id) FROM categories), 1))"
            )

            # Create posts table
            await conn.execute('''
                CREATE TABLE IF NOT EXISTS posts (
                    id SERIAL PRIMARY KEY,
                    title VARCHAR(200) NOT NULL,
                    content TEXT NOT NULL,
                    author VARCHAR(100) NOT NULL,
                    category_id INTEGER NOT NULL REFERENCES categories(id),
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            ''')

            # Create indexes
            await conn.execute('CREATE INDEX IF NOT EXISTS idx_posts_author ON posts(author)')
            await conn.execute('CREATE INDEX IF NOT EXISTS idx_posts_created_at ON posts(created_at DESC)')
            await conn.execute('CREATE INDEX IF NOT EXISTS idx_posts_category_id ON posts(category_id)')

        logger.info("PostgreSQL blog database schema initialized")

    async def _initialize_sqlite_schema(self):
        """Initialize SQLite database schema."""
        os.makedirs(os.path.dirname(DATABASE_PATH), exist_ok=True)
        async with aiosqlite.connect(DATABASE_PATH) as conn:
            # Create categories table
            await conn.execute('''
                CREATE TABLE IF NOT EXISTS categories (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    slug TEXT NOT NULL UNIQUE,
                    color TEXT DEFAULT '#6B7280'
                )
            ''')

            # Insert default categories if not exist
            cursor = await conn.execute("SELECT COUNT(*) FROM categories")
            count = await cursor.fetchone()
            if count[0] == 0:
                await conn.execute('''
                    INSERT INTO categories (id, name, slug, color) VALUES
                    (1, '기술 스택', 'tech-stack', '#3B82F6'),
                    (2, 'Troubleshooting', 'troubleshooting', '#E9754A'),
                    (3, 'Test', 'test', '#757575')
                ''')

            # Create posts table
            await conn.execute('''
                CREATE TABLE IF NOT EXISTS posts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL,
                    content TEXT NOT NULL,
                    author TEXT NOT NULL,
                    category_id INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    FOREIGN KEY (category_id) REFERENCES categories(id)
                )
            ''')
            await conn.execute('CREATE INDEX IF NOT EXISTS idx_posts_category_id ON posts(category_id)')
            await conn.commit()

        logger.info("SQLite blog database schema initialized")

    async def get_or_create_category(self, category_name: str) -> Dict:
        """Get existing category or create new one with random color.
        Delegates to CategoryRepository.
        """
        return await self._category_repo.get_or_create(category_name)

    async def cleanup_empty_categories(self) -> int:
        """Delete categories with no posts. Returns number of deleted categories.
        Delegates to CategoryRepository.
        """
        return await self._category_repo.cleanup_empty()

    async def get_posts(self, offset: int, limit: int, category_slug: Optional[str] = None) -> List[Dict]:
        """Fetch paginated posts with category info, ordered by id DESC.
        Delegates to PostRepository.
        """
        return await self._post_repo.get_all(offset=offset, limit=limit, category_slug=category_slug)

    async def get_post_by_id(self, post_id: int) -> Optional[Dict]:
        """Fetch single post by ID with category info.
        Delegates to PostRepository.
        """
        return await self._post_repo.get_by_id(post_id)

    async def get_categories_with_counts(self) -> List[Dict]:
        """Fetch all categories with post counts.
        Delegates to CategoryRepository.
        """
        return await self._category_repo.get_all()

    async def create_post(self, title: str, content: str, author: str, category_id: int) -> Dict:
        """Create a new post and return it with category info.
        Delegates to PostRepository.
        """
        return await self._post_repo.create({
            "title": title,
            "content": content,
            "author": author,
            "category_id": category_id
        })

    async def get_post_author(self, post_id: int) -> Optional[str]:
        """Get the author of a post for permission checking.
        Delegates to PostRepository.
        """
        return await self._post_repo.get_author(post_id)

    async def update_post(self, post_id: int, title: Optional[str], content: Optional[str], category_id: Optional[int]) -> Optional[Dict]:
        """Update a post and return the updated post with category info.
        Delegates to PostRepository.
        """
        data = {}
        if title is not None:
            data["title"] = title
        if content is not None:
            data["content"] = content
        if category_id is not None:
            data["category_id"] = category_id
        return await self._post_repo.update(post_id, data)

    async def delete_post(self, post_id: int) -> bool:
        """Delete a post. Returns True if deleted, False if not found.
        Delegates to PostRepository.
        """
        return await self._post_repo.delete(post_id)

    async def delete_post_atomic(self, post_id: int, author: str) -> bool:
        """Atomic delete with author check. Returns True if deleted, False if not found or not author.
        Delegates to PostRepository.
        """
        return await self._post_repo.delete_atomic(post_id, author)

    async def update_post_atomic(
        self,
        post_id: int,
        author: str,
        title: Optional[str],
        content: Optional[str],
        category_id: Optional[int]
    ) -> Optional[Dict]:
        """Atomic update with author check. Returns updated post or None if not found/not author.
        Delegates to PostRepository.
        """
        data = {}
        if title is not None:
            data["title"] = title
        if content is not None:
            data["content"] = content
        if category_id is not None:
            data["category_id"] = category_id
        return await self._post_repo.update_atomic(post_id, author, data)

    async def get_post_count(self) -> int:
        """Get total number of posts.
        Delegates to PostRepository.
        """
        return await self._post_repo.count()

    async def close(self):
        """Close database connection pool."""
        if self.use_postgres and self.pool:
            await self.pool.close()
            logger.info("PostgreSQL connection pool closed")


# Singleton instance
db = BlogDatabase()
