from __future__ import annotations

import sqlite3
from pathlib import Path

from alembic import command

from home_agent.config import Settings
from home_agent.db import alembic_config


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
    } <= tables
    command.downgrade(config, "base")
    with sqlite3.connect(database) as connection:
        tables = {
            row[0]
            for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
    assert "households" not in tables
