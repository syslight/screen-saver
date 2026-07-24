from __future__ import annotations

import asyncio
from datetime import UTC, datetime
from typing import Any

import httpx
from websockets.asyncio.client import ClientConnection, connect

from home_agent.protocol.envelope import make_envelope, parse_envelope
from home_agent.protocol.messages import (
    CapabilitiesPayload,
    Capability,
    CommandRequestPayload,
    CommandResultPayload,
    HeartbeatPayload,
    HelloPayload,
)
from linux_room_node.config import NodeCredentials


class FakeRoomNodeClient:
    def __init__(self, server_url: str, credentials: NodeCredentials) -> None:
        self.server_url = server_url.rstrip("/")
        self.credentials = credentials
        self._sequence = 0

    @classmethod
    async def pair(cls, server_url: str, code: str, *, name: str = "客厅假节点") -> NodeCredentials:
        async with httpx.AsyncClient(base_url=server_url, trust_env=False) as client:
            response = await client.post(
                "/api/v1/nodes/pair",
                json={"code": code, "name": name, "platform": "linux-fake"},
            )
            response.raise_for_status()
            return NodeCredentials.model_validate(response.json())

    def _next_sequence(self) -> int:
        self._sequence += 1
        return self._sequence

    def _ws_url(self) -> str:
        scheme = "wss" if self.server_url.startswith("https://") else "ws"
        host = self.server_url.split("://", 1)[-1]
        return f"{scheme}://{host}/api/v1/nodes/ws"

    async def _send(self, connection: ClientConnection, message_type: str, payload: object) -> None:
        envelope = make_envelope(
            message_type,
            payload,  # type: ignore[arg-type]
            sequence=self._next_sequence(),
            node_id=self.credentials.node_id,
            room_id=self.credentials.room_id,
        )
        await connection.send(envelope.model_dump_json(by_alias=True))

    async def announce(self, connection: ClientConnection) -> None:
        await self._send(
            connection,
            "node.hello",
            HelloPayload(
                device_key=self.credentials.device_key.get_secret_value(),
                software_version="0.1.0",
                platform="linux-fake",
                media_protocol_version=0,
            ),
        )
        await self._send(
            connection,
            "node.capabilities",
            CapabilitiesPayload(
                capabilities=[
                    Capability(
                        capability_id="fake-camera",
                        type="camera",
                        status="online",
                        properties={"supportsStill": True, "width": 1920, "height": 1080},
                        commands=["fake.set_status"],
                    ),
                    Capability(
                        capability_id="fake-mic-array",
                        type="microphone_array",
                        status="online",
                        properties={"channels": 4},
                        commands=["fake.set_status"],
                    ),
                    Capability(
                        capability_id="fake-speaker",
                        type="speaker",
                        status="online",
                        properties={"volumeControl": True},
                        commands=["fake.set_status"],
                    ),
                ]
            ),
        )

    async def heartbeat(self, connection: ClientConnection) -> None:
        while True:
            await asyncio.sleep(15)
            await self._send(
                connection,
                "heartbeat.ping",
                HeartbeatPayload(nonce=datetime.now(UTC).isoformat()),
            )

    async def receive(self, connection: ClientConnection) -> None:
        async for raw in connection:
            if not isinstance(raw, str):
                continue
            parsed = parse_envelope(__import__("json").loads(raw))
            if not isinstance(parsed.payload, CommandRequestPayload):
                continue
            command = parsed.payload.command_name
            success = command in {"fake.echo", "fake.set_status"}
            result: dict[str, Any] = (
                {"echo": parsed.payload.arguments} if command == "fake.echo" else {}
            )
            await self._send(
                connection,
                "command.result",
                CommandResultPayload(
                    request_message_id=parsed.envelope.message_id,
                    success=success,
                    result=result,
                    error_code=None if success else "unsupported_command",
                ),
            )

    async def run_once(self) -> None:
        self._sequence = 0
        async with connect(self._ws_url()) as connection:
            await self.announce(connection)
            heartbeat = asyncio.create_task(self.heartbeat(connection))
            try:
                await self.receive(connection)
            finally:
                heartbeat.cancel()
                await asyncio.gather(heartbeat, return_exceptions=True)

    async def run_forever(self) -> None:
        delay = 1.0
        while True:
            try:
                await self.run_once()
                delay = 1.0
            except asyncio.CancelledError:
                raise
            except Exception:
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30.0)
