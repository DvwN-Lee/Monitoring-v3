# blog-service/app/repositories/__init__.py
from app.repositories.post_repository import PostRepository
from app.repositories.category_repository import CategoryRepository

__all__ = ["PostRepository", "CategoryRepository"]
