# blog-service/app/models/schemas.py
from typing import Optional
from pydantic import BaseModel, Field


class PostCreate(BaseModel):
    title: str = Field(..., min_length=1, max_length=120)
    content: str = Field(..., min_length=1, max_length=20000)
    category_name: str = Field(..., min_length=1, max_length=50)


class PostUpdate(BaseModel):
    title: Optional[str] = Field(None, min_length=1, max_length=120)
    content: Optional[str] = Field(None, min_length=1, max_length=20000)
    category_name: Optional[str] = Field(None, min_length=1, max_length=50)
