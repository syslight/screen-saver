from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from home_agent.app import create_app
from home_agent.config import Settings


def test_cloud_mode_only_exposes_control_plane_routes(tmp_path: Path) -> None:
    app = create_app(Settings(data_dir=tmp_path, deployment_mode="cloud"))
    with TestClient(app) as client:
        assert client.get("/health/ready").status_code == 200
        assert client.get("/parent/").status_code == 404
        assert client.get("/api/v1/homework/members").status_code == 404
        assert client.post("/api/v1/student/pair", json={}).status_code == 404
        assert (
            client.post(
                "/api/v1/bootstrap",
                json={
                    "householdName": "云端测试家庭",
                    "username": "parent1",
                    "password": "correct-password",
                },
            ).status_code
            == 201
        )
