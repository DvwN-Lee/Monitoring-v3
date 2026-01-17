# blog-service/app/repositories/base.py
from abc import ABC, abstractmethod
from typing import Optional, List, Dict, Any, Generic, TypeVar

T = TypeVar("T")


class BaseRepository(ABC, Generic[T]):
    """Abstract base repository class defining the standard CRUD interface."""

    @abstractmethod
    async def get_by_id(self, entity_id: int) -> Optional[T]:
        """Retrieve a single entity by its ID."""
        pass

    @abstractmethod
    async def get_all(
        self, offset: int = 0, limit: int = 20, **filters: Any
    ) -> List[T]:
        """Retrieve multiple entities with pagination and optional filters."""
        pass

    @abstractmethod
    async def create(self, data: Dict[str, Any]) -> T:
        """Create a new entity and return it."""
        pass

    @abstractmethod
    async def update(
        self, entity_id: int, data: Dict[str, Any]
    ) -> Optional[T]:
        """Update an existing entity and return the updated version."""
        pass

    @abstractmethod
    async def delete(self, entity_id: int) -> bool:
        """Delete an entity. Returns True if successful."""
        pass

    @abstractmethod
    async def count(self, **filters: Any) -> int:
        """Count entities matching the given filters."""
        pass
