"""Add categories table and category_id to posts

Revision ID: 89ccc5842f08
Revises: 
Create Date: 2025-11-06 11:13:11.709666

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '89ccc5842f08'
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # Step 1: Create categories table
    op.create_table(
        'categories',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('name', sa.String(length=50), nullable=False),
        sa.Column('slug', sa.String(length=50), nullable=False),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('name'),
        sa.UniqueConstraint('slug')
    )

    # Step 2: Insert default categories
    op.execute("""
        INSERT INTO categories (id, name, slug) VALUES
        (1, '기술 스택', 'tech-stack'),
        (2, 'Troubleshooting', 'troubleshooting'),
        (3, 'Test', 'test')
    """)

    # Step 3: Add category_id column to posts table (nullable for now)
    op.add_column('posts', sa.Column('category_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_posts_category_id', 'posts', 'categories', ['category_id'], ['id'])
    op.create_index('idx_posts_category_id', 'posts', ['category_id'])

    # Step 4: Backfill existing posts with default category (기술 스택 = id 1)
    op.execute("UPDATE posts SET category_id = 1 WHERE category_id IS NULL")

    # Step 5: Make category_id NOT NULL
    op.alter_column('posts', 'category_id', nullable=False)


def downgrade() -> None:
    """Downgrade schema."""
    # Remove foreign key and index
    op.drop_index('idx_posts_category_id', table_name='posts')
    op.drop_constraint('fk_posts_category_id', 'posts', type_='foreignkey')

    # Remove category_id column
    op.drop_column('posts', 'category_id')

    # Drop categories table
    op.drop_table('categories')
