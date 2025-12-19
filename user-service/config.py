# user-service/config.py
import os
from dataclasses import dataclass

@dataclass
class ServerConfig:
    host: str = '0.0.0.0'
    port: int = 8001

@dataclass
class DatabaseConfig:
    # getenv를 사용하여 환경변수를 읽고, 값이 없으면 기본값을 사용하도록 변경
    db_file: str = os.getenv('DATABASE_PATH', '/data/app.db')

@dataclass
class CacheConfig:
    host: str = os.getenv('REDIS_HOST', 'redis-service')
    port: int = int(os.getenv('REDIS_PORT', '6379'))
    default_ttl: int = 300

class Config:
    def __init__(self):
        self.server = ServerConfig()
        self.database = DatabaseConfig()
        self.cache = CacheConfig()
        self.REDIS_URL = f"redis://{self.cache.host}:{self.cache.port}"

config = Config()