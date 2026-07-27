from __future__ import annotations

import json
from typing import Any

import httpx
from websockets.asyncio.client import ClientConnection, connect

ALLOWED_FRAME_ACTIONS = {
    "next_photo",
    "prev_photo",
    "refresh_weather",
    "set_volume",
    "set_music_enabled",
    "set_music_muted",
    "set_music_volume",
    "announce",
    "text_command",
}


class LocalFrameClient:
    def __init__(
        self,
        frame_ws_url: str = "ws://127.0.0.1:8780/ws",
        agent_url: str = "http://127.0.0.1:8790",
    ) -> None:
        self.frame_ws_url = frame_ws_url
        self.agent_url = agent_url.rstrip("/")

    async def frame_state(self) -> dict[str, Any]:
        async with connect(self.frame_ws_url, open_timeout=5) as connection:
            return await self._next_state(connection)

    async def frame_command(self, arguments: dict[str, Any]) -> dict[str, Any]:
        action = arguments.get("action")
        if not isinstance(action, str) or action not in ALLOWED_FRAME_ACTIONS:
            raise ValueError("unsupported_frame_action")
        command: dict[str, Any] = {"type": "command", "action": action}
        text = arguments.get("text")
        value = arguments.get("value")
        if text is not None:
            if not isinstance(text, str) or len(text) > 2_000:
                raise ValueError("invalid_frame_text")
            command["text"] = text
        if value is not None:
            if not isinstance(value, (int, float)):
                raise ValueError("invalid_frame_value")
            command["value"] = float(value)
        async with connect(self.frame_ws_url, open_timeout=5) as connection:
            initial = await self._next_state(connection)
            await connection.send(json.dumps(command, ensure_ascii=False))
            result = await self._next_state(connection)
        if action not in {"next_photo", "prev_photo"}:
            return result
        if result.get("photo") == initial.get("photo"):
            result["transitionPending"] = True
        return result

    async def home_status(self) -> dict[str, Any]:
        agent_ready = False
        try:
            async with httpx.AsyncClient(
                base_url=self.agent_url, timeout=5, trust_env=False
            ) as client:
                response = await client.get("/health/ready")
                agent_ready = response.status_code == 200
        except httpx.HTTPError:
            pass
        frame_state: dict[str, Any] | None = None
        try:
            frame_state = await self.frame_state()
        except (OSError, TimeoutError):
            pass
        return {
            "agentReady": agent_ready,
            "frameOnline": frame_state is not None,
            "frameState": frame_state,
        }

    async def _next_state(self, connection: ClientConnection) -> dict[str, Any]:
        for _ in range(8):
            raw = await connection.recv()
            if not isinstance(raw, str):
                continue
            message = json.loads(raw)
            if isinstance(message, dict) and message.get("type") == "state":
                return message
        raise TimeoutError("frame_state_not_received")
