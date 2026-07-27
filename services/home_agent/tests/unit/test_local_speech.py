from __future__ import annotations

import base64
import gzip
import io
import json
import struct
import wave
from pathlib import Path

import httpx
import pytest
from pydantic import SecretStr

from home_agent.config import Settings
from home_agent.services.local_speech import (
    FallbackSpeechSynthesizer,
    OpenAiSpeechRecognizer,
    OpenAiSpeechSynthesizer,
    VolcanoAsrSession,
    VolcanoStreamingAsr,
    VolcanoUnidirectionalTts,
    pcm_to_wav,
    stream_synthesized_pcm,
)


def test_pcm_to_wav_wraps_display_audio() -> None:
    result = pcm_to_wav(b"\x01\x00\xff\x7f", sample_rate=22_050)

    with wave.open(io.BytesIO(result), "rb") as source:
        assert source.getnchannels() == 1
        assert source.getsampwidth() == 2
        assert source.getframerate() == 22_050
        assert source.readframes(2) == b"\x01\x00\xff\x7f"


class FailingTts:
    async def synthesize(self, text: str) -> bytes:
        raise RuntimeError("unavailable")


class WorkingTts:
    async def synthesize(self, text: str) -> bytes:
        return f"fallback:{text}".encode()


class WorkingWavTts:
    async def synthesize(self, text: str) -> bytes:
        assert text == "你好"
        return pcm_to_wav(b"\x01\x00\x02\x00", sample_rate=22050)


@pytest.mark.asyncio
async def test_tts_falls_back_without_exposing_provider_error() -> None:
    synthesizer = FallbackSpeechSynthesizer(FailingTts(), WorkingTts())

    assert await synthesizer.synthesize("你好") == "fallback:你好".encode()


@pytest.mark.asyncio
async def test_non_streaming_tts_is_exposed_as_pcm_chunks() -> None:
    chunks = [chunk async for chunk in stream_synthesized_pcm(WorkingWavTts(), "你好")]

    assert [chunk.data for chunk in chunks] == [b"\x01\x00\x02\x00"]
    assert chunks[0].sample_rate == 22050


def test_volcano_tts_payload_uses_selected_voice_and_parameters(tmp_path: Path) -> None:
    provider = VolcanoUnidirectionalTts(
        Settings(
            data_dir=tmp_path,
            voice_volcano_voice="family-voice",
            voice_volcano_sample_rate=48_000,
            voice_volcano_speech_rate=20,
            voice_volcano_pitch_rate=3,
            voice_volcano_loudness_rate=8,
        )
    )

    payload = provider._payload("你好")
    params = payload["req_params"]
    assert isinstance(params, dict)
    assert params["speaker"] == "family-voice"
    assert params["audio_params"] == {
        "format": "pcm",
        "sample_rate": 48_000,
        "speech_rate": 20,
        "loudness_rate": 8,
    }
    assert json.loads(params["additions"])["post_process"]["pitch"] == 3


@pytest.mark.asyncio
async def test_volcano_tts_uses_api_key_and_streams_base64_pcm(tmp_path: Path) -> None:
    requests: list[httpx.Request] = []
    first = b"\x01\x00\x02\x00"
    second = b"\x03\x00\x04\x00"

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        events = [
            {"code": 0, "message": "", "data": base64.b64encode(first).decode()},
            {"code": 0, "message": "", "data": base64.b64encode(second).decode()},
            {"code": 0, "message": "", "sentence": {"text": "你好"}},
            {"code": 20_000_000, "message": "OK"},
        ]
        content = "\n".join(json.dumps(event) for event in events).encode()
        return httpx.Response(200, content=content)

    settings = Settings(
        data_dir=tmp_path,
        voice_volcano_api_key=SecretStr("tts-app-key"),
        voice_volcano_tts_url="https://speech.test/api/v3/tts/unidirectional",
        voice_volcano_resource_id="tts-resource",
        voice_volcano_voice="family-voice",
    )
    provider = VolcanoUnidirectionalTts(settings, transport=httpx.MockTransport(handler))

    chunks = [chunk async for chunk in provider.stream_pcm("你好")]

    assert b"".join(chunk.data for chunk in chunks) == first + second
    assert all(chunk.sample_rate == 24_000 for chunk in chunks)
    assert len(requests) == 1
    assert requests[0].headers["x-api-key"] == "tts-app-key"
    assert requests[0].headers["x-api-resource-id"] == "tts-resource"
    assert requests[0].url.path == "/api/v3/tts/unidirectional"
    body = json.loads(requests[0].content)
    assert body["req_params"]["audio_params"]["format"] == "pcm"


def test_volcano_asr_protocol_builds_request_audio_and_parses_result(tmp_path: Path) -> None:
    provider = VolcanoStreamingAsr(Settings(data_dir=tmp_path))
    request = provider._request_frame(b'{"request":true}')
    assert request[:4] == bytes([0x11, 0x11, 0x11, 0])
    sequence, size = struct.unpack(">ii", request[4:12])
    assert sequence == 1
    assert gzip.decompress(request[12 : 12 + size]) == b'{"request":true}'

    audio = provider._audio_frame(-3, b"pcm")
    assert audio[:4] == bytes([0x11, 0x23, 0x01, 0])
    assert struct.unpack(">i", audio[4:8])[0] == -3
    payload = gzip.compress(json.dumps({"result": {"text": "你好"}}).encode())
    response = bytes([0x11, 0x93, 0x11, 0]) + struct.pack(">iI", -3, len(payload)) + payload
    is_last, decoded = provider._parse_response(response)
    assert is_last is True
    assert decoded["result"]["text"] == "你好"


def test_volcano_asr_protocol_rejects_error_frame(tmp_path: Path) -> None:
    provider = VolcanoStreamingAsr(Settings(data_dir=tmp_path))
    payload = b'{"error":"secret provider details"}'
    frame = bytes([0x11, 0xF0, 0x10, 0]) + struct.pack(">II", 45000000, len(payload)) + payload
    with pytest.raises(RuntimeError, match="45000000"):
        provider._parse_response(frame)


def test_volcano_asr_uses_only_selected_authentication_mode(tmp_path: Path) -> None:
    app_key_provider = VolcanoStreamingAsr(
        Settings(
            data_dir=tmp_path,
            voice_volcano_asr_auth_mode="app_key",
            voice_volcano_api_key=SecretStr("new-app-key"),
            voice_volcano_app_id="legacy-app",
            voice_volcano_access_token=SecretStr("legacy-token"),
        )
    )
    assert app_key_provider.configured is True
    assert app_key_provider._auth_headers() == {"X-Api-Key": "new-app-key"}

    legacy_provider = VolcanoStreamingAsr(
        Settings(
            data_dir=tmp_path,
            voice_volcano_asr_auth_mode="app_id_token",
            voice_volcano_api_key=SecretStr("ignored-app-key"),
            voice_volcano_app_id="legacy-app",
            voice_volcano_access_token=SecretStr("legacy-token"),
        )
    )
    assert legacy_provider.configured is True
    assert legacy_provider._auth_headers() == {
        "X-Api-App-Key": "legacy-app",
        "X-Api-Access-Key": "legacy-token",
    }


def test_volcano_asr_requires_credentials_for_selected_mode(tmp_path: Path) -> None:
    provider = VolcanoStreamingAsr(
        Settings(
            data_dir=tmp_path,
            voice_volcano_asr_auth_mode="app_key",
            voice_volcano_app_id="legacy-app",
            voice_volcano_access_token=SecretStr("legacy-token"),
        )
    )
    assert provider.configured is False
    with pytest.raises(RuntimeError, match="credentials are not configured"):
        provider._auth_headers()


class FakeWebSocket:
    def __init__(self, responses: list[bytes]) -> None:
        self.responses = responses
        self.sent: list[bytes] = []
        self.closed = False

    async def send(self, payload: bytes) -> None:
        self.sent.append(payload)

    async def recv(self) -> bytes:
        return self.responses.pop(0)

    async def close(self) -> None:
        self.closed = True


@pytest.mark.asyncio
async def test_volcano_asr_session_streams_pcm_and_returns_latest_text(tmp_path: Path) -> None:
    provider = VolcanoStreamingAsr(Settings(data_dir=tmp_path))
    partial = gzip.compress(json.dumps({"result": {"text": "你"}}).encode())
    final = gzip.compress(json.dumps({"result": {"text": "你好"}}).encode())
    frames = [
        bytes([0x11, 0x91, 0x11, 0]) + struct.pack(">iI", 1, len(partial)) + partial,
        bytes([0x11, 0x93, 0x11, 0]) + struct.pack(">iI", -3, len(final)) + final,
    ]
    websocket = FakeWebSocket(frames)
    session = VolcanoAsrSession(provider, websocket)

    await session.send_audio(b"pcm")
    assert await session.finish() == "你好"
    assert len(websocket.sent) == 2
    assert websocket.closed is True


@pytest.mark.asyncio
async def test_openai_speech_providers_use_audio_endpoints(tmp_path: Path) -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.path.endswith("/transcriptions"):
            return httpx.Response(200, json={"text": "识别结果"})
        if json.loads(request.content)["response_format"] == "pcm":
            return httpx.Response(200, content=b"\x01\x00\x02\x00")
        return httpx.Response(200, content=b"RIFF-test-wav")

    settings = Settings(
        data_dir=tmp_path,
        voice_openai_base_url="https://speech.test/v1",
        voice_openai_api_key=SecretStr("private-key"),
        voice_openai_asr_language="yue",
        voice_openai_tts_speed=1.25,
    )
    transport = httpx.MockTransport(handler)
    recognizer = OpenAiSpeechRecognizer(settings, transport=transport)
    synthesizer = OpenAiSpeechSynthesizer(settings, transport=transport)

    assert recognizer.configured is True
    assert await recognizer.transcribe(b"\0\0" * 160) == "识别结果"
    assert synthesizer.configured is True
    assert await synthesizer.synthesize("你好") == b"RIFF-test-wav"
    streamed = [chunk async for chunk in synthesizer.stream_pcm("你好")]
    assert b"".join(chunk.data for chunk in streamed) == b"\x01\x00\x02\x00"
    assert streamed[0].sample_rate == 24000
    assert [request.url.path for request in requests] == [
        "/v1/audio/transcriptions",
        "/v1/audio/speech",
        "/v1/audio/speech",
    ]
    assert all(request.headers["authorization"] == "Bearer private-key" for request in requests)
    assert b"gpt-4o-mini-transcribe" in requests[0].content
    assert b'name="language"\r\n\r\nyue' in requests[0].content
    assert json.loads(requests[1].content)["response_format"] == "wav"
    assert json.loads(requests[1].content)["speed"] == 1.25
    assert json.loads(requests[2].content)["response_format"] == "pcm"


@pytest.mark.asyncio
async def test_cloud_speech_requires_credentials(tmp_path: Path) -> None:
    settings = Settings(data_dir=tmp_path)
    assert VolcanoStreamingAsr(settings).configured is False
    with pytest.raises(RuntimeError, match="Volcano ASR credentials"):
        await VolcanoStreamingAsr(settings).open_stream()
    with pytest.raises(RuntimeError, match="OpenAI ASR credentials"):
        await OpenAiSpeechRecognizer(settings).transcribe(b"pcm")
    with pytest.raises(RuntimeError, match="OpenAI TTS credentials"):
        await OpenAiSpeechSynthesizer(settings).synthesize("你好")
    with pytest.raises(RuntimeError, match="Volcano TTS credentials"):
        await VolcanoUnidirectionalTts(settings).synthesize("你好")
