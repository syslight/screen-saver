from __future__ import annotations

import asyncio
import socket
from pathlib import Path

import httpx
import pytest
import uvicorn

from home_agent.app import create_app
from home_agent.config import Settings
from linux_room_node.client import FakeRoomNodeClient


def _available_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


@pytest.mark.asyncio
async def test_live_server_and_fake_node_command_round_trip(tmp_path: Path) -> None:
    port = _available_port()
    app = create_app(
        Settings(
            data_dir=tmp_path,
            command_timeout_seconds=2,
            heartbeat_timeout_seconds=5,
        )
    )
    server = uvicorn.Server(
        uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error", lifespan="on")
    )
    server_task = asyncio.create_task(server.serve())
    for _ in range(100):
        if server.started:
            break
        await asyncio.sleep(0.01)
    assert server.started
    base_url = f"http://127.0.0.1:{port}"
    node_task: asyncio.Task[None] | None = None
    try:
        async with httpx.AsyncClient(base_url=base_url, trust_env=False) as client:
            bootstrap = await client.post(
                "/api/v1/bootstrap",
                json={
                    "householdName": "Live Test",
                    "username": "parent",
                    "password": "live-test-password",
                },
            )
            login = await client.post(
                "/api/v1/auth/login",
                json={"username": "parent", "password": "live-test-password"},
            )
            token = login.json()["token"]
            headers = {"Authorization": f"Bearer {token}"}
            pairing = await client.post(
                "/api/v1/node-pairing-codes",
                headers=headers,
                json={"roomId": bootstrap.json()["roomId"]},
            )
            credentials = await FakeRoomNodeClient.pair(
                base_url, pairing.json()["code"], name="live-fake-node"
            )
            node = FakeRoomNodeClient(base_url, credentials)
            node_task = asyncio.create_task(node.run_once())
            for _ in range(100):
                details = await client.get(f"/api/v1/nodes/{credentials.node_id}", headers=headers)
                if details.json()["status"] == "online" and details.json()["capabilities"]:
                    break
                await asyncio.sleep(0.01)
            assert details.json()["status"] == "online"
            assert len(details.json()["capabilities"]) == 3
            command = await client.post(
                f"/api/v1/nodes/{credentials.node_id}/commands",
                headers=headers,
                json={"commandName": "fake.echo", "arguments": {"text": "live"}},
            )
            assert command.status_code == 200
            assert command.json()["result"] == {"echo": {"text": "live"}}
    finally:
        if node_task is not None:
            node_task.cancel()
            await asyncio.gather(node_task, return_exceptions=True)
        server.should_exit = True
        await server_task
