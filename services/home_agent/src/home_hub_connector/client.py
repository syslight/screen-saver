from __future__ import annotations

import asyncio
import json
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
from home_hub_connector.local_frame import LocalFrameClient
from linux_room_node.config import NodeCredentials


class HomeHubConnector:
    def __init__(
        self,
        cloud_url: str,
        credentials: NodeCredentials,
        local: LocalFrameClient | None = None,
    ) -> None:
        self.cloud_url = cloud_url.rstrip("/")
        self.credentials = credentials
        self.local = local or LocalFrameClient()
        self._sequence = 0

    @classmethod
    async def pair(
        cls, cloud_url: str, code: str, *, name: str = "家庭主服务器"
    ) -> NodeCredentials:
        async with httpx.AsyncClient(base_url=cloud_url, trust_env=False, timeout=15) as client:
            response = await client.post(
                "/api/v1/nodes/pair",
                json={"code": code, "name": name, "platform": "linux-home-hub"},
            )
            response.raise_for_status()
            return NodeCredentials.model_validate(response.json())

    def _next_sequence(self) -> int:
        self._sequence += 1
        return self._sequence

    def _ws_url(self) -> str:
        scheme = "wss" if self.cloud_url.startswith("https://") else "ws"
        host = self.cloud_url.split("://", 1)[-1]
        return f"{scheme}://{host}/api/v1/nodes/ws"

    async def _send(self, connection: ClientConnection, message_type: str, payload: object) -> None:
        message = make_envelope(
            message_type,
            payload,  # type: ignore[arg-type]
            sequence=self._next_sequence(),
            node_id=self.credentials.node_id,
            room_id=self.credentials.room_id,
        )
        await connection.send(message.model_dump_json(by_alias=True))

    async def announce(self, connection: ClientConnection) -> None:
        await self._send(
            connection,
            "node.hello",
            HelloPayload(
                device_key=self.credentials.device_key.get_secret_value(),
                software_version="0.1.0",
                platform="linux-home-hub",
                media_protocol_version=0,
            ),
        )
        await self._send(
            connection,
            "node.capabilities",
            CapabilitiesPayload(
                capabilities=[
                    Capability(
                        capability_id="home-hub",
                        type="home.hub",
                        status="online",
                        properties={"primary": True, "privacyMode": "local-first"},
                        commands=["home.status"],
                    ),
                    Capability(
                        capability_id="smart-frame",
                        type="display.photo",
                        status="online",
                        properties={"controlProtocolVersion": 1},
                        commands=["frame.get_state", "frame.command"],
                    ),
                    Capability(
                        capability_id="smart-frame-audio",
                        type="audio.playback",
                        status="online",
                        properties={"musicControl": True, "ttsControl": True},
                        commands=["frame.command"],
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

    async def _execute(self, command: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if command == "home.status":
            return await self.local.home_status()
        if command == "frame.get_state":
            return await self.local.frame_state()
        if command == "frame.command":
            return await self.local.frame_command(arguments)
        raise ValueError("unsupported_command")

    async def receive(self, connection: ClientConnection) -> None:
        async for raw in connection:
            if not isinstance(raw, str):
                continue
            parsed = parse_envelope(json.loads(raw))
            if not isinstance(parsed.payload, CommandRequestPayload):
                continue
            success = True
            error_code: str | None = None
            result: dict[str, Any] = {}
            try:
                result = await self._execute(parsed.payload.command_name, parsed.payload.arguments)
            except ValueError as exc:
                success = False
                error_code = str(exc)
            except (OSError, TimeoutError, httpx.HTTPError):
                success = False
                error_code = "local_service_unavailable"
            await self._send(
                connection,
                "command.result",
                CommandResultPayload(
                    request_message_id=parsed.envelope.message_id,
                    success=success,
                    result=result,
                    error_code=error_code,
                ),
            )

    async def run_once(self) -> None:
        self._sequence = 0
        async with connect(self._ws_url(), open_timeout=15) as connection:
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
