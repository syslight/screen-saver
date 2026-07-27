"""Add one-time parent app enrollment codes.

Revision ID: 0005_parent_enrollment
Revises: 0004_homework_inspections
Create Date: 2026-07-26
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0005_parent_enrollment"
down_revision: str | None = "0004_homework_inspections"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("auth_sessions") as batch:
        batch.add_column(sa.Column("client_name", sa.String(120)))
        batch.add_column(sa.Column("platform", sa.String(40)))
    op.create_table(
        "parent_enrollment_codes",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("code_hash", sa.String(64), nullable=False, unique=True),
        sa.Column(
            "household_id",
            sa.String(36),
            sa.ForeignKey("households.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "user_id",
            sa.String(36),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True)),
        sa.Column("created_by", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        "ix_parent_enrollment_codes_code_hash",
        "parent_enrollment_codes",
        ["code_hash"],
    )


def downgrade() -> None:
    op.drop_table("parent_enrollment_codes")
    with op.batch_alter_table("auth_sessions") as batch:
        batch.drop_column("platform")
        batch.drop_column("client_name")
