from __future__ import annotations

from collections.abc import AsyncIterator, Iterator
from pathlib import Path

import httpx
import pytest
import pytest_asyncio
from fastapi import FastAPI
from fastapi.testclient import TestClient

from home_agent.app import create_app
from home_agent.config import Settings


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        data_dir=tmp_path,
        session_ttl_seconds=3600,
        pairing_ttl_seconds=300,
        command_timeout_seconds=1,
        heartbeat_timeout_seconds=2,
    )


@pytest.fixture
def app(settings: Settings) -> FastAPI:
    return create_app(settings)


@pytest.fixture
def client(app: FastAPI) -> Iterator[TestClient]:
    with TestClient(app) as test_client:
        yield test_client


@pytest_asyncio.fixture
async def async_client(app: FastAPI) -> AsyncIterator[httpx.AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as value:
            yield value


def bootstrap(client: TestClient) -> dict[str, str]:
    response = client.post(
        "/api/v1/bootstrap",
        json={
            "householdName": "测试家庭",
            "timezone": "Asia/Shanghai",
            "username": "parent1",
            "password": "correct-password",
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def login(client: TestClient) -> str:
    response = client.post(
        "/api/v1/auth/login",
        json={"username": "parent1", "password": "correct-password"},
    )
    assert response.status_code == 200, response.text
    return response.json()["token"]


def pair_node(client: TestClient, token: str, room_id: str) -> dict[str, str]:
    code_response = client.post(
        "/api/v1/node-pairing-codes",
        headers={"Authorization": f"Bearer {token}"},
        json={"roomId": room_id},
    )
    assert code_response.status_code == 201, code_response.text
    response = client.post(
        "/api/v1/nodes/pair",
        json={"code": code_response.json()["code"], "name": "测试节点", "platform": "fake"},
    )
    assert response.status_code == 201, response.text
    return response.json()
