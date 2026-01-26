# user-service/database_service.py (Hybrid: SQLite + PostgreSQL with asyncpg)
import os
import logging
from typing import Optional, Dict

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, InvalidHash
from werkzeug.security import check_password_hash

logger = logging.getLogger(__name__)

# Argon2id PasswordHasher (OWASP 권장)
ph = PasswordHasher(
    time_cost=3,        # Iteration 횟수
    memory_cost=65536,  # 64MB 메모리 사용
    parallelism=4,      # 병렬 처리 수
)

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

            # SSL mode configuration (asyncpg uses ssl parameter, not sslmode)
            ssl_mode = os.getenv('POSTGRES_SSLMODE', 'disable').lower()
            ssl_enabled = ssl_mode not in ('disable', 'false', 'no', '0')

            self.db_config = {
                'host': os.getenv('POSTGRES_HOST', 'postgresql-service'),
                'port': int(os.getenv('POSTGRES_PORT', '5432')),
                'database': os.getenv('POSTGRES_DB', 'titanium'),
                'user': os.getenv('POSTGRES_USER', 'postgres'),
                'password': postgres_password,
                'ssl': ssl_enabled,
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
                    min_size=2,
                    max_size=20,
                    timeout=30,
                    command_timeout=10,
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
        """Add a new user with Argon2id hashed password."""
        password_hash = ph.hash(password)

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
        """Verify user credentials with Argon2 and legacy PBKDF2 fallback."""
        user = await self.get_user_by_username(username)
        if not user:
            return None

        password_hash = user['password_hash']
        user_info = {
            "id": user["id"],
            "username": user["username"],
            "email": user["email"]
        }

        # Argon2 Hash 검증 시도
        if password_hash.startswith('$argon2'):
            try:
                ph.verify(password_hash, password)
                # Rehash if parameters changed
                if ph.check_needs_rehash(password_hash):
                    new_hash = ph.hash(password)
                    await self._update_password_hash(user['id'], new_hash)
                    logger.info(f"Rehashed password for user '{username}' with updated Argon2 parameters")
                return user_info
            except VerifyMismatchError:
                return None

        # Legacy PBKDF2 Fallback (점진적 마이그레이션)
        if check_password_hash(password_hash, password):
            # 마이그레이션: Argon2로 재해시
            new_hash = ph.hash(password)
            await self._update_password_hash(user['id'], new_hash)
            logger.info(f"Migrated password hash for user '{username}' from PBKDF2 to Argon2")
            return user_info

        return None

    async def _update_password_hash(self, user_id: int, new_hash: str):
        """Update password hash for a user."""
        try:
            if self.use_postgres:
                async with self.pool.acquire() as conn:
                    await conn.execute(
                        "UPDATE users SET password_hash = $1 WHERE id = $2",
                        new_hash, user_id
                    )
            else:
                async with aiosqlite.connect(self.db_file) as conn:
                    await conn.execute(
                        "UPDATE users SET password_hash = ? WHERE id = ?",
                        (new_hash, user_id)
                    )
                    await conn.commit()
        except Exception as e:
            logger.error(f"Error updating password hash for user ID {user_id}: {e}", exc_info=True)

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
