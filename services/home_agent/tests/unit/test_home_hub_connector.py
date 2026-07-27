from __future__ import annotations

import json
from unittest.mock import AsyncMock

import pytest

from home_agent.protocol.envelope import make_envelope, parse_envelope
from home_agent.protocol.messages import CommandRequestPayload
from home_hub_connector.client import HomeHubConnector
from home_hub_connector.local_frame import LocalFrameClient
from linux_room_node.config import NodeCredentials


def credentials() -> NodeCredentials:
    return NodeCredentials.model_validate(
        {
            "nodeId": "20000000-0000-4000-8000-000000000001",
            "roomId": "30000000-0000-4000-8000-000000000001",
            "deviceKey": "a-long-enough-device-key-for-tests",
        }
    )


class FakeConnection:
    def __init__(self, incoming: list[str] | None = None) -> None:
        self.sent: list[str] = []
        self.incoming = incoming or []

    async def send(self, value: str) -> None:
        self.sent.append(value)

    def __aiter__(self) -> FakeConnection:
        return self

    async def __anext__(self) -> str:
        if not self.incoming:
            raise StopAsyncIteration
        return self.incoming.pop(0)


@pytest.mark.asyncio
async def test_home_hub_announces_generic_capabilities() -> None:
    connector = HomeHubConnector("https://cloud.example", credentials())
    connection = FakeConnection()
    await connector.announce(connection)  # type: ignore[arg-type]
    parsed = [parse_envelope(json.loads(item)) for item in connection.sent]
    assert [item.envelope.type for item in parsed] == ["node.hello", "node.capabilities"]
    capabilities = parsed[1].payload.capabilities  # type: ignore[attr-defined]
    assert {item.type for item in capabilities} == {
        "home.hub",
        "display.photo",
        "audio.playback",
    }
    assert connector._ws_url() == "wss://cloud.example/api/v1/nodes/ws"


@pytest.mark.asyncio
async def test_home_hub_routes_frame_commands_and_rejects_unknown() -> None:
    local = AsyncMock(spec=LocalFrameClient)
    local.frame_command.return_value = {"type": "state", "photo": "one.jpg"}
    connector = HomeHubConnector("http://cloud.test:8790", credentials(), local)
    command = make_envelope(
        "command.request",
        CommandRequestPayload(command_name="frame.command", arguments={"action": "next_photo"}),
        sequence=1,
        node_id=credentials().node_id,
        room_id=credentials().room_id,
    ).model_dump_json(by_alias=True)
    unknown = make_envelope(
        "command.request",
        CommandRequestPayload(command_name="camera.raw_stream", arguments={}),
        sequence=2,
        node_id=credentials().node_id,
        room_id=credentials().room_id,
    ).model_dump_json(by_alias=True)
    connection = FakeConnection([command, unknown])
    await connector.receive(connection)  # type: ignore[arg-type]
    first = parse_envelope(json.loads(connection.sent[0])).payload
    second = parse_envelope(json.loads(connection.sent[1])).payload
    assert first.success is True  # type: ignore[attr-defined]
    assert first.result["photo"] == "one.jpg"  # type: ignore[attr-defined]
    assert second.success is False  # type: ignore[attr-defined]
    assert second.error_code == "unsupported_command"  # type: ignore[attr-defined]
    local.frame_command.assert_awaited_once_with({"action": "next_photo"})


@pytest.mark.asyncio
async def test_local_frame_rejects_unlisted_actions_before_connecting() -> None:
    client = LocalFrameClient()
    with pytest.raises(ValueError, match="unsupported_frame_action"):
        await client.frame_command({"action": "camera.raw_stream"})
