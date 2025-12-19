import os
from sqlalchemy import Column, Integer, String, Text, TIMESTAMP, ForeignKey, create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func

Base = declarative_base()

class Category(Base):
    __tablename__ = 'categories'

    id = Column(Integer, primary_key=True)
    name = Column(String(50), nullable=False, unique=True)
    slug = Column(String(50), nullable=False, unique=True)

    posts = relationship("Post", back_populates="category")

class Post(Base):
    __tablename__ = 'posts'

    id = Column(Integer, primary_key=True)
    title = Column(String(200), nullable=False)
    content = Column(Text, nullable=False)
    author = Column(String(100), nullable=False)
    category_id = Column(Integer, ForeignKey('categories.id'), nullable=True)
    created_at = Column(TIMESTAMP, server_default=func.current_timestamp(), nullable=False)
    updated_at = Column(TIMESTAMP, server_default=func.current_timestamp(), onupdate=func.current_timestamp(), nullable=False)

    category = relationship("Category", back_populates="posts")

def get_database_url():
    """Get database URL from environment variables."""
    USE_POSTGRES = os.getenv('USE_POSTGRES', 'false').lower() == 'true'

    if USE_POSTGRES:
        host = os.getenv('POSTGRES_HOST', 'postgresql-service')
        port = os.getenv('POSTGRES_PORT', '5432')
        database = os.getenv('POSTGRES_DB', 'titanium')
        user = os.getenv('POSTGRES_USER', 'postgres')
        password = os.getenv('POSTGRES_PASSWORD', '')
        return f'postgresql://{user}:{password}@{host}:{port}/{database}'
    else:
        database_path = os.getenv('BLOG_DATABASE_PATH', '/app/blog.db')
        return f'sqlite:///{database_path}'
