# user-service/database_service.py (Hybrid: SQLite + PostgreSQL with asyncpg)
import os
import logging
from typing import Optional, Dict

from werkzeug.security import generate_password_hash, check_password_hash

logger = logging.getLogger(__name__)

# Determine which DB to use based on environment variable
USE_POSTGRES = os.getenv('USE_POSTGRES', 'false').lower() == 'true'

if USE_POSTGRES:
    import asyncpg
    logger.info("🐘 Using PostgreSQL database with asyncpg")
else:
    import sqlite3
    import aiosqlite
    logger.info("💾 Using SQLite database")


class UserServiceDatabase:
    def __init__(self):
        self.use_postgres = USE_POSTGRES
        self.pool: Optional[asyncpg.Pool] = None
        self._initialized = False

        if self.use_postgres:
            # PostgreSQL connection parameters
            postgres_password = os.getenv('POSTGRES_PASSWORD')
            if not postgres_password:
                raise ValueError(
                    "POSTGRES_PASSWORD environment variable is required for PostgreSQL. "
                    "Please set it in Kubernetes Secret or environment variables."
                )

            self.db_config = {
                'host': os.getenv('POSTGRES_HOST', 'postgresql-service'),
                'port': int(os.getenv('POSTGRES_PORT', '5432')),
                'database': os.getenv('POSTGRES_DB', 'titanium'),
                'user': os.getenv('POSTGRES_USER', 'postgres'),
                'password': postgres_password,
            }
        else:
            # SQLite configuration
            self.db_file = os.getenv('DATABASE_PATH', '/data/users.db')

    async def initialize(self):
        """Initialize database connection pool and schema."""
        if self._initialized:
            return

        if self.use_postgres:
            try:
                self.pool = await asyncpg.create_pool(
                    min_size=5,
                    max_size=20,
                    **self.db_config
                )
                logger.info(f"PostgreSQL connection pool created: {self.db_config['host']}:{self.db_config['port']}")
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
            await conn.execute('''
                CREATE TABLE IF NOT EXISTS users (
                    id SERIAL PRIMARY KEY,
                    username VARCHAR(100) UNIQUE NOT NULL,
                    email VARCHAR(255) NOT NULL,
                    password_hash VARCHAR(255) NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            ''')
            await conn.execute('''
                CREATE INDEX IF NOT EXISTS idx_users_username ON users(username)
            ''')
        logger.info("PostgreSQL user database schema initialized")

    async def _initialize_sqlite_schema(self):
        """Initialize SQLite database schema."""
        os.makedirs(os.path.dirname(self.db_file), exist_ok=True)
        async with aiosqlite.connect(self.db_file) as conn:
            await conn.execute('''
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    username TEXT UNIQUE NOT NULL,
                    email TEXT NOT NULL,
                    password_hash TEXT NOT NULL
                )
            ''')
            await conn.commit()
        logger.info("SQLite user database schema initialized")

    async def add_user(self, username: str, email: str, password: str) -> Optional[int]:
        """Add a new user with hashed password."""
        # Optimized PBKDF2 iterations: 100000 -> 60000 for better performance
        # Still secure (NIST minimum: 10000, this is 6x higher)
        password_hash = generate_password_hash(password, method='pbkdf2:sha256:60000')

        try:
            if self.use_postgres:
                async with self.pool.acquire() as conn:
                    try:
                        user_id = await conn.fetchval(
                            "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id",
                            username, email, password_hash
                        )
                        logger.info(f"User '{username}' added with ID {user_id}")
                        return user_id
                    except asyncpg.UniqueViolationError:
                        logger.warning(f"User '{username}' already exists")
                        return None
            else:
                async with aiosqlite.connect(self.db_file) as conn:
                    try:
                        cursor = await conn.execute(
                            "INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)",
                            (username, email, password_hash)
                        )
                        await conn.commit()
                        return cursor.lastrowid
                    except aiosqlite.IntegrityError:
                        logger.warning(f"User '{username}' already exists")
                        return None
        except Exception as e:
            logger.error(f"Error adding user: {e}", exc_info=True)
            return None

    async def get_user_by_username(self, username: str) -> Optional[Dict]:
        """Get user information by username."""
        try:
            if self.use_postgres:
                async with self.pool.acquire() as conn:
                    row = await conn.fetchrow(
                        "SELECT id, username, email, password_hash, created_at FROM users WHERE username = $1",
                        username
                    )
                    return dict(row) if row else None
            else:
                async with aiosqlite.connect(self.db_file) as conn:
                    conn.row_factory = aiosqlite.Row
                    cursor = await conn.execute(
                        "SELECT * FROM users WHERE username = ?",
                        (username,)
                    )
                    row = await cursor.fetchone()
                    return dict(row) if row else None
        except Exception as e:
            logger.error(f"Error getting user by username: {e}", exc_info=True)
            return None

    async def get_user_by_id(self, user_id: int) -> Optional[Dict]:
        """Get user information by ID."""
        try:
            if self.use_postgres:
                async with self.pool.acquire() as conn:
                    row = await conn.fetchrow(
                        "SELECT id, username, email, password_hash, created_at FROM users WHERE id = $1",
                        user_id
                    )
                    return dict(row) if row else None
            else:
                async with aiosqlite.connect(self.db_file) as conn:
                    conn.row_factory = aiosqlite.Row
                    cursor = await conn.execute(
                        "SELECT * FROM users WHERE id = ?",
                        (user_id,)
                    )
                    row = await cursor.fetchone()
                    return dict(row) if row else None
        except Exception as e:
            logger.error(f"Error getting user by ID: {e}", exc_info=True)
            return None

    async def verify_user_credentials(self, username: str, password: str) -> Optional[Dict]:
        """Verify user credentials."""
        user = await self.get_user_by_username(username)
        if user and check_password_hash(user['password_hash'], password):
            # Return user info without password_hash
            return {
                "id": user["id"],
                "username": user["username"],
                "email": user["email"]
            }
        return None

    async def health_check(self) -> bool:
        """Check database connection health."""
        try:
            if self.use_postgres:
                async with self.pool.acquire() as conn:
                    await conn.fetchval("SELECT 1")
            else:
                async with aiosqlite.connect(self.db_file) as conn:
                    await conn.execute("SELECT 1")
            return True
        except Exception as e:
            logger.error(f"Database health check failed: {e}")
            return False

    async def close(self):
        """Close database connection pool."""
        if self.use_postgres and self.pool:
            await self.pool.close()
            logger.info("PostgreSQL connection pool closed")
