# blog-service/app/config.py
import os
import logging

logger = logging.getLogger(__name__)

# Auth Service URL
AUTH_SERVICE_URL = os.getenv('AUTH_SERVICE_URL', 'http://auth-service:8002')

# Redis Configuration
REDIS_HOST = os.getenv('REDIS_HOST', 'redis-service')
REDIS_PORT = int(os.getenv('REDIS_PORT', '6379'))
REDIS_URL = f"redis://{REDIS_HOST}:{REDIS_PORT}"

# Determine which DB to use
USE_POSTGRES = os.getenv('USE_POSTGRES', 'false').lower() == 'true'

if USE_POSTGRES:
    logger.info("🐘 Using PostgreSQL database for blog posts")

    # SSL mode configuration (asyncpg uses ssl parameter, not sslmode)
    ssl_mode = os.getenv('POSTGRES_SSLMODE', 'disable').lower()
    ssl_enabled = ssl_mode not in ('disable', 'false', 'no', '0')

    DB_CONFIG = {
        'host': os.getenv('POSTGRES_HOST', 'postgresql-service'),
        'port': int(os.getenv('POSTGRES_PORT', '5432')),
        'database': os.getenv('POSTGRES_DB', 'titanium'),
        'user': os.getenv('POSTGRES_USER', 'postgres'),
        'password': os.getenv('POSTGRES_PASSWORD', ''),
        'ssl': ssl_enabled,
    }
    DATABASE_PATH = None
else:
    logger.info("💾 Using SQLite database for blog posts")
    DATABASE_PATH = os.getenv('BLOG_DATABASE_PATH', '/app/blog.db')
    DB_CONFIG = None

# Prometheus Metrics Configuration
REQUEST_LATENCY_BUCKETS = (
    0.001,
    0.005,
    0.01,
    0.025,
    0.05,
    0.075,
    0.1,
    0.25,
    0.5,
    0.75,
    1.0,
    2.5,
    5.0,
    10.0,
)
