from __future__ import annotations

import asyncio
import sqlite3
from pathlib import Path

import pytest
from alembic import command

from home_agent.config import Settings
from home_agent.db import alembic_config, upgrade_database


@pytest.mark.asyncio
async def test_default_sqlite_database_and_data_directory_are_private(tmp_path: Path) -> None:
    settings = Settings(data_dir=tmp_path)

    await upgrade_database(settings)

    directory_stat = await asyncio.to_thread(tmp_path.stat)
    database_stat = await asyncio.to_thread((tmp_path / "home_agent.db").stat)
    assert directory_stat.st_mode & 0o777 == 0o700
    assert database_stat.st_mode & 0o777 == 0o600


def test_foundation_migration_upgrades_and_downgrades(tmp_path: Path) -> None:
    settings = Settings(data_dir=tmp_path)
    settings.ensure_directories()
    config = alembic_config(settings)
    command.upgrade(config, "head")
    database = tmp_path / "home_agent.db"
    with sqlite3.connect(database) as connection:
        tables = {
            row[0]
            for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
    assert {
        "households",
        "users",
        "auth_sessions",
        "rooms",
        "pairing_codes",
        "nodes",
        "node_capabilities",
        "audit_events",
        "household_members",
        "homework_tasks",
        "homework_submissions",
        "submission_assets",
        "homework_reviews",
        "homework_events",
        "student_pairing_codes",
        "student_devices",
        "homework_inspections",
        "parent_enrollment_codes",
    } <= tables
    command.downgrade(config, "base")
    with sqlite3.connect(database) as connection:
        tables = {
            row[0]
            for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
    assert "households" not in tables
