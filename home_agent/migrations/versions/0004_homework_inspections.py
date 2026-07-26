"""Create homework inspection table.

Revision ID: 0004_homework_inspections
Revises: 0003_student_devices
Create Date: 2026-07-24
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0004_homework_inspections"
down_revision: str | None = "0003_student_devices"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "homework_inspections",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "household_id",
            sa.String(36),
            sa.ForeignKey("households.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "submission_id",
            sa.String(36),
            sa.ForeignKey("homework_submissions.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("requested_by", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("status", sa.String(32), nullable=False),
        sa.Column("model_name", sa.String(120), nullable=False),
        sa.Column("prompt_version", sa.String(40), nullable=False),
        sa.Column("image_quality", sa.String(24)),
        sa.Column("summary", sa.Text()),
        sa.Column("confidence", sa.Float()),
        sa.Column("suggested_decision", sa.String(20)),
        sa.Column("items_json", sa.JSON(), nullable=False),
        sa.Column("error_code", sa.String(80)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
    )
    op.create_index(
        "ix_homework_inspections_household_id", "homework_inspections", ["household_id"]
    )
    op.create_index(
        "ix_homework_inspections_submission_id", "homework_inspections", ["submission_id"]
    )
    op.create_index("ix_homework_inspections_status", "homework_inspections", ["status"])


def downgrade() -> None:
    op.drop_table("homework_inspections")
