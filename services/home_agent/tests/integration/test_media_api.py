from __future__ import annotations

import sqlite3
import struct
from pathlib import Path
from typing import Any

from conftest import bootstrap, login, pair_node
from fastapi.testclient import TestClient

from home_agent.protocol.envelope import make_envelope
from home_agent.protocol.messages import HelloPayload, VoiceTurnStartPayload, VoiceTurnStopPayload
from home_agent.services.voice_agent import (
    VoiceAgentResult,
    VoiceAudioChunkEvent,
    VoiceAudioStartEvent,
    VoiceTranscriptEvent,
)


class FakeVoiceAgent:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, bytes]] = []

    async def process(self, pcm: bytes, *, node_id: str, turn_id: str) -> VoiceAgentResult:
        self.calls.append((node_id, turn_id, pcm))
        return VoiceAgentResult("你好", f"回复 {node_id}", b"fake-wav", True)


class FakeStreamingVoiceAgent(FakeVoiceAgent):
    async def process_stream(
        self,
        pcm: bytes,
        *,
        node_id: str,
        turn_id: str,
        emit: Any,
        asr_stream: object = None,
    ) -> VoiceAgentResult:
        assert asr_stream is None
        self.calls.append((node_id, turn_id, pcm))
        await emit(VoiceTranscriptEvent("你好"))
        await emit(VoiceAudioStartEvent(24000, 1, "流式回复。"))
        await emit(VoiceAudioChunkEvent(b"pcm-1"))
        await emit(VoiceAudioChunkEvent(b"pcm-2"))
        return VoiceAgentResult("你好", "流式回复。", b"", True)


def _prepare_media(client: TestClient, tmp_path: Path) -> tuple[dict[str, str], str]:
    photo = tmp_path / "visible.jpg"
    photo.write_bytes(b"jpeg-data")
    hidden = tmp_path / "hidden.jpg"
    hidden.write_bytes(b"hidden-data")
    database = tmp_path / "photo_index.db"
    with sqlite3.connect(database) as connection:
        connection.executescript(
            """
            CREATE TABLE photos (
              id TEXT PRIMARY KEY, hidden INTEGER, is_photo INTEGER, taken_at INTEGER,
              caption TEXT, location_name TEXT, tags TEXT
            );
            CREATE TABLE faces (photo_id TEXT, subject_name TEXT);
            CREATE TABLE person_profiles (
              subject_name TEXT, identity_label TEXT, confirmed INTEGER, sort_order INTEGER
            );
            """
        )
        connection.execute(
            "INSERT INTO photos VALUES (?,?,?,?,?,?,?)",
            (str(photo), 0, 1, 1234, "公园里的宝宝", "广州动物园", "孩子 风景"),
        )
        connection.execute(
            "INSERT INTO photos VALUES (?,?,?,?,?,?,?)",
            (str(hidden), 1, 1, 2345, "重复照片", None, None),
        )
        connection.execute("INSERT INTO faces VALUES (?,?)", (str(photo), "person_1"))
        connection.execute(
            "INSERT INTO person_profiles VALUES (?,?,?,?)", ("person_1", "宝宝", 1, 1)
        )
    music = tmp_path / "music" / "childhood"
    music.mkdir(parents=True)
    (music / "Childhood.mp3").write_bytes(b"music-data")
    client.app.state.settings.media_photo_database = database
    client.app.state.settings.media_music_dir = tmp_path / "music"

    created = bootstrap(client)
    token = login(client)
    paired = pair_node(client, token, created["roomId"])
    auth = f"Node {paired['nodeId']}:{paired['deviceKey']}"
    return paired, auth


def test_authenticated_media_api_filters_hidden_and_serves_music(
    client: TestClient, tmp_path: Path
) -> None:
    _paired, auth = _prepare_media(client, tmp_path)
    headers = {"Authorization": auth}

    unauthorized = client.get("/api/v1/media/photos")
    assert unauthorized.status_code == 401
    listing = client.get("/api/v1/media/photos", headers=headers)
    assert listing.status_code == 200
    payload = listing.json()
    assert payload["total"] == 1
    assert [item["name"] for item in payload["photos"]] == ["visible.jpg"]

    photo_id = payload["photos"][0]["id"]
    content = client.get(f"/api/v1/media/photos/{photo_id}/content", headers=headers)
    assert content.content == b"jpeg-data"
    description = client.get(f"/api/v1/media/photos/{photo_id}/description", headers=headers).json()
    assert description["identities"] == ["宝宝"]

    selection = client.get(
        "/api/v1/media/music/select", headers=headers, params={"photoId": photo_id}
    )
    assert selection.status_code == 200
    assert selection.json()["mood"] == "childhood"
    track = client.get(selection.json()["contentUrl"], headers=headers)
    assert track.content == b"music-data"


def test_voice_turn_routes_audio_back_to_authenticated_source(
    client: TestClient, tmp_path: Path
) -> None:
    paired, _auth = _prepare_media(client, tmp_path)
    fake = FakeVoiceAgent()
    client.app.state.voice_agent = fake
    node_id = paired["nodeId"]
    room_id = paired["roomId"]
    turn_id = "turn-voice-0001"

    def envelope(message_type: str, payload: Any, sequence: int) -> dict[str, object]:
        return make_envelope(
            message_type,
            payload,
            sequence=sequence,
            node_id=node_id,
            room_id=room_id,
        ).json_dict()

    with client.websocket_connect("/api/v1/media/voice/ws") as socket:
        socket.send_json(
            envelope(
                "node.hello",
                HelloPayload(
                    device_key=paired["deviceKey"],
                    software_version="1.0.0",
                    platform="android",
                    media_protocol_version=1,
                ),
                1,
            )
        )
        socket.send_json(envelope("voice.turn.start", VoiceTurnStartPayload(turn_id=turn_id), 2))
        listening = socket.receive_json()
        assert listening["payload"]["targetNodeId"] == node_id
        socket.send_bytes(b"pcm")
        socket.send_json(envelope("voice.turn.stop", VoiceTurnStopPayload(turn_id=turn_id), 3))
        assert socket.receive_json()["payload"]["state"] == "processing"
        speaking = socket.receive_json()
        assert speaking["payload"]["reply"] == f"回复 {node_id}"
        play = socket.receive_json()
        assert play["type"] == "audio.play"
        assert socket.receive_bytes() == b"fake-wav"
        idle = socket.receive_json()
        assert idle["payload"]["targetNodeId"] == node_id
        assert idle["payload"]["state"] == "idle"
        assert idle["payload"]["continueDialog"] is True

    assert fake.calls == [(node_id, turn_id, b"pcm")]


def test_cancelled_voice_turn_skips_agent(client: TestClient, tmp_path: Path) -> None:
    paired, _auth = _prepare_media(client, tmp_path)
    fake = FakeVoiceAgent()
    client.app.state.voice_agent = fake

    def envelope(message_type: str, payload: Any, sequence: int) -> dict[str, object]:
        return make_envelope(
            message_type,
            payload,
            sequence=sequence,
            node_id=paired["nodeId"],
            room_id=paired["roomId"],
        ).json_dict()

    with client.websocket_connect("/api/v1/media/voice/ws") as socket:
        socket.send_json(
            envelope(
                "node.hello",
                HelloPayload(
                    device_key=paired["deviceKey"],
                    software_version="1.0.0",
                    platform="android",
                    media_protocol_version=1,
                ),
                1,
            )
        )
        turn_id = "turn-voice-cancelled"
        socket.send_json(envelope("voice.turn.start", VoiceTurnStartPayload(turn_id=turn_id), 2))
        assert socket.receive_json()["payload"]["state"] == "listening"
        socket.send_json(
            envelope(
                "voice.turn.stop",
                VoiceTurnStopPayload(turn_id=turn_id, cancelled=True),
                3,
            )
        )
        idle = socket.receive_json()
        assert idle["payload"]["state"] == "idle"
        assert idle["payload"]["continueDialog"] is False

    assert fake.calls == []


def test_media_protocol_v2_streams_pcm_before_final_turn_state(
    client: TestClient, tmp_path: Path
) -> None:
    paired, _auth = _prepare_media(client, tmp_path)
    fake = FakeStreamingVoiceAgent()
    client.app.state.voice_agent = fake
    node_id = paired["nodeId"]
    room_id = paired["roomId"]
    turn_id = "turn-voice-stream"

    def envelope(message_type: str, payload: Any, sequence: int) -> dict[str, object]:
        return make_envelope(
            message_type,
            payload,
            sequence=sequence,
            node_id=node_id,
            room_id=room_id,
        ).json_dict()

    with client.websocket_connect("/api/v1/media/voice/ws") as socket:
        socket.send_json(
            envelope(
                "node.hello",
                HelloPayload(
                    device_key=paired["deviceKey"],
                    software_version="2.0.0",
                    platform="android",
                    media_protocol_version=2,
                ),
                1,
            )
        )
        socket.send_json(envelope("voice.turn.start", VoiceTurnStartPayload(turn_id=turn_id), 2))
        assert socket.receive_json()["payload"]["state"] == "listening"
        socket.send_bytes(b"pcm")
        socket.send_json(envelope("voice.turn.stop", VoiceTurnStopPayload(turn_id=turn_id), 3))
        assert socket.receive_json()["payload"]["state"] == "processing"
        recognized = socket.receive_json()
        assert recognized["payload"]["transcript"] == "你好"
        assert socket.receive_json()["payload"]["state"] == "speaking"
        start = socket.receive_json()
        assert start["type"] == "audio.stream.start"
        assert start["payload"]["sampleRate"] == 24000
        assert socket.receive_bytes() == b"pcm-1pcm-2"
        end = socket.receive_json()
        assert end["type"] == "audio.stream.end"
        assert end["payload"]["byteLength"] == 10
        idle = socket.receive_json()
        assert idle["payload"]["state"] == "idle"
        assert idle["payload"]["reply"] == "流式回复。"

    assert fake.calls == [(node_id, turn_id, b"pcm")]


def test_voice_turn_is_ended_by_home_agent_silence_detection(
    client: TestClient, tmp_path: Path
) -> None:
    paired, _auth = _prepare_media(client, tmp_path)
    fake = FakeVoiceAgent()
    client.app.state.voice_agent = fake
    turn_id = "turn-server-endpoint"

    def envelope(message_type: str, payload: Any, sequence: int) -> dict[str, object]:
        return make_envelope(
            message_type,
            payload,
            sequence=sequence,
            node_id=paired["nodeId"],
            room_id=paired["roomId"],
        ).json_dict()

    speech = struct.pack("<1920h", *([2_000] * 1920))
    silence = struct.pack("<11200h", *([0] * 11200))
    with client.websocket_connect("/api/v1/media/voice/ws") as socket:
        socket.send_json(
            envelope(
                "node.hello",
                HelloPayload(
                    device_key=paired["deviceKey"],
                    software_version="1.0.0",
                    platform="android",
                    media_protocol_version=1,
                ),
                1,
            )
        )
        socket.send_json(envelope("voice.turn.start", VoiceTurnStartPayload(turn_id=turn_id), 2))
        assert socket.receive_json()["payload"]["state"] == "listening"
        socket.send_bytes(speech)
        socket.send_bytes(silence)

        assert socket.receive_json()["payload"]["state"] == "processing"
        assert socket.receive_json()["payload"]["state"] == "speaking"
        assert socket.receive_json()["type"] == "audio.play"
        assert socket.receive_bytes() == b"fake-wav"
        assert socket.receive_json()["payload"]["state"] == "idle"

    assert fake.calls == [(paired["nodeId"], turn_id, speech + silence)]
