from __future__ import annotations

import asyncio
import json
from argparse import Namespace
from pathlib import Path
from unittest.mock import AsyncMock

import pytest

from home_agent.protocol.envelope import make_envelope, parse_envelope
from home_agent.protocol.messages import CommandRequestPayload
from linux_room_node import fake
from linux_room_node.client import FakeRoomNodeClient
from linux_room_node.config import NodeCredentials, default_credentials_path


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
async def test_announce_and_receive_echo_command() -> None:
    node = FakeRoomNodeClient("http://localhost:8790", credentials())
    connection = FakeConnection()
    await node.announce(connection)  # type: ignore[arg-type]
    assert [parse_envelope(json.loads(item)).envelope.type for item in connection.sent] == [
        "node.hello",
        "node.capabilities",
    ]
    capabilities = parse_envelope(json.loads(connection.sent[1])).payload
    assert len(capabilities.capabilities) == 3  # type: ignore[attr-defined]

    command = make_envelope(
        "command.request",
        CommandRequestPayload(command_name="fake.echo", arguments={"text": "你好"}),
        sequence=1,
        node_id=credentials().node_id,
        room_id=credentials().room_id,
    ).model_dump_json(by_alias=True)
    receiver = FakeConnection([command])
    await node.receive(receiver)  # type: ignore[arg-type]
    result = parse_envelope(json.loads(receiver.sent[0])).payload
    assert result.success is True  # type: ignore[attr-defined]
    assert result.result == {"echo": {"text": "你好"}}  # type: ignore[attr-defined]


@pytest.mark.asyncio
async def test_unsupported_command_and_heartbeat(monkeypatch: pytest.MonkeyPatch) -> None:
    node = FakeRoomNodeClient("https://example.test", credentials())
    assert node._ws_url() == "wss://example.test/api/v1/nodes/ws"
    command = make_envelope(
        "command.request",
        CommandRequestPayload(command_name="unknown", arguments={}),
        sequence=1,
        node_id=credentials().node_id,
        room_id=credentials().room_id,
    ).model_dump_json(by_alias=True)
    receiver = FakeConnection([command, b"ignored"])  # type: ignore[list-item]
    await node.receive(receiver)  # type: ignore[arg-type]
    result = parse_envelope(json.loads(receiver.sent[0])).payload
    assert result.success is False  # type: ignore[attr-defined]
    assert result.error_code == "unsupported_command"  # type: ignore[attr-defined]

    calls = 0

    async def one_sleep(_seconds: float) -> None:
        nonlocal calls
        calls += 1
        if calls > 1:
            raise asyncio.CancelledError

    monkeypatch.setattr(asyncio, "sleep", one_sleep)
    heartbeat_connection = FakeConnection()
    with pytest.raises(asyncio.CancelledError):
        await node.heartbeat(heartbeat_connection)  # type: ignore[arg-type]
    heartbeat = parse_envelope(json.loads(heartbeat_connection.sent[0]))
    assert heartbeat.envelope.type == "heartbeat.ping"


def test_cli_parser_and_default_path() -> None:
    parsed = fake.build_parser().parse_args(["--server", "http://test", "--name", "room"])
    assert parsed.server == "http://test"
    assert parsed.name == "room"
    assert default_credentials_path().name == "fake-node.json"


@pytest.mark.asyncio
async def test_cli_run_pairs_once_and_never_prints_key(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    stored = tmp_path / "credentials.json"
    pair = AsyncMock(return_value=credentials())
    run_forever = AsyncMock(return_value=None)
    monkeypatch.setattr(FakeRoomNodeClient, "pair", pair)
    monkeypatch.setattr(FakeRoomNodeClient, "run_forever", run_forever)
    args = Namespace(
        server="http://test",
        credentials=stored,
        pairing_code="one-time-code",
        name="room",
    )
    await fake.run(args)
    assert stored.exists()
    assert "a-long-enough-device-key" not in capsys.readouterr().out
    run_forever.assert_awaited_once()

    await fake.run(
        Namespace(
            server="http://test",
            credentials=stored,
            pairing_code=None,
            name="room",
        )
    )
    assert run_forever.await_count == 2
