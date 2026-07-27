from __future__ import annotations

import asyncio
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from pydantic import SecretStr

from home_agent.config import Settings
from home_agent.services.coding_agent import CodingAgentProvider
from home_agent.services.local_speech import PcmAudioChunk
from home_agent.services.voice_agent import (
    VoiceAgentService,
    VoiceAudioChunkEvent,
    VoiceAudioStartEvent,
    VoiceTranscriptEvent,
    _SentenceBuffer,
)
from home_agent.services.voice_providers import VoiceProviderRegistry, VoiceProviderSelection


class FakeAsr:
    async def transcribe(self, pcm: bytes) -> str:
        assert pcm
        return "今天星期几"


class FakeTts:
    async def synthesize(self, text: str) -> bytes:
        assert text == "今天是星期日。"
        return b"wav"


class ExitAsr:
    async def transcribe(self, pcm: bytes) -> str:
        return "先这样吧"


class SilentAsr:
    async def transcribe(self, pcm: bytes) -> str:
        assert pcm
        return ""


class ExitTts:
    async def synthesize(self, text: str) -> bytes:
        assert text == "好的，需要我时叫小方。"
        return b"exit-wav"


@pytest.mark.asyncio
async def test_voice_agent_runs_asr_response_and_tts_on_server(tmp_path: Path) -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(
            200,
            content=(
                'data: {"choices":[{"delta":{"content":"今天是"}}]}\n\n'
                'data: {"choices":[{"delta":{"content":"星期日。"}}]}\n\n'
                "data: [DONE]\n\n"
            ).encode(),
            headers={"content-type": "text/event-stream"},
        )

    settings = Settings(
        data_dir=tmp_path,
        voice_glm_api_key=SecretStr("test-key"),
        voice_glm_base_url="https://glm.test/v1",
    )
    agent = CodingAgentProvider(settings, transport=httpx.MockTransport(handler))
    service = VoiceAgentService(settings, asr=FakeAsr(), tts=FakeTts(), agent=agent)
    result = await service.process(b"\0\0" * 160, node_id="node-1", turn_id="turn-1")

    assert result.transcript == "今天星期几"
    assert result.reply == "今天是星期日。"
    assert result.audio == b"wav"
    assert [request.url.path for request in requests] == ["/v1/chat/completions"]
    assert requests[0].headers["authorization"] == "Bearer test-key"


@pytest.mark.asyncio
async def test_voice_agent_without_coding_key_does_not_run_speech_models(tmp_path: Path) -> None:
    service = VoiceAgentService(Settings(data_dir=tmp_path))

    result = await service.process(b"pcm", node_id="node-1", turn_id="turn-1")

    assert result.transcript == ""
    assert result.reply == "家庭语音 Agent 尚未配置。"
    assert result.audio == b""
    assert result.continue_dialog is False


@pytest.mark.asyncio
async def test_voice_agent_exit_phrase_closes_continuous_dialog(tmp_path: Path) -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(500)

    settings = Settings(data_dir=tmp_path, voice_glm_api_key=SecretStr("test-key"))
    agent = CodingAgentProvider(settings, transport=httpx.MockTransport(handler))
    service = VoiceAgentService(settings, asr=ExitAsr(), tts=ExitTts(), agent=agent)

    result = await service.process(b"pcm", node_id="node-1", turn_id="turn-exit")

    assert result.transcript == "先这样吧"
    assert result.reply == "好的，需要我时叫小方。"
    assert result.audio == b"exit-wav"
    assert result.continue_dialog is False
    assert requests == []


class RegistryLlm:
    configured = True
    config = SimpleNamespace(model="fake-model")

    def __init__(self) -> None:
        self.cleared: list[str] = []

    async def reply(self, transcript: str, *, node_id: str) -> str:
        assert transcript == "今天星期几"
        assert node_id == "node-1"
        return "今天是星期日。"

    def clear(self, node_id: str) -> None:
        self.cleared.append(node_id)


class StreamingRegistryLlm(RegistryLlm):
    async def reply_stream(self, transcript: str, *, node_id: str):
        assert transcript == "今天星期几"
        assert node_id == "node-1"
        yield "今天是"
        yield "星期日。"


class StreamingTts:
    async def synthesize(self, text: str) -> bytes:
        raise AssertionError("streaming path must not aggregate WAV")

    async def stream_pcm(self, text: str):
        assert text == "今天是星期日。"
        yield PcmAudioChunk(b"pcm-1", sample_rate=24000)
        yield PcmAudioChunk(b"pcm-2", sample_rate=24000)


class FixedReplyStreamingTts:
    def __init__(self) -> None:
        self.texts: list[str] = []

    async def synthesize(self, text: str) -> bytes:
        raise AssertionError("streaming path must not aggregate WAV")

    async def stream_pcm(self, text: str):
        self.texts.append(text)
        yield PcmAudioChunk(b"fixed-pcm", sample_rate=24000)


class GatedStreamingLlm(RegistryLlm):
    def __init__(self, first_sentence_started: asyncio.Event) -> None:
        super().__init__()
        self.first_sentence_started = first_sentence_started

    async def reply_stream(self, transcript: str, *, node_id: str):
        assert transcript == "今天星期几"
        assert node_id == "node-1"
        yield "第一句。"
        await asyncio.wait_for(self.first_sentence_started.wait(), timeout=1)
        yield "第二句。"


class GatedStreamingTts:
    def __init__(self, first_sentence_started: asyncio.Event) -> None:
        self.first_sentence_started = first_sentence_started
        self.texts: list[str] = []

    async def synthesize(self, text: str) -> bytes:
        raise AssertionError("streaming path must not aggregate WAV")

    async def stream_pcm(self, text: str):
        self.texts.append(text)
        if len(self.texts) == 1:
            self.first_sentence_started.set()
        yield PcmAudioChunk(text.encode(), sample_rate=24000)


def test_sentence_buffer_releases_complete_and_bounded_sentences() -> None:
    buffer = _SentenceBuffer()

    assert buffer.add("第一句还没") == []
    assert buffer.add("说完。第二句！尾巴") == ["第一句还没说完。", "第二句！"]
    assert buffer.finish() == "尾巴"
    assert buffer.add("字" * 41) == ["字" * 40]
    assert buffer.finish() == "字"


@pytest.mark.asyncio
async def test_voice_agent_uses_runtime_provider_registry(tmp_path: Path) -> None:
    settings = Settings(data_dir=tmp_path, voice_glm_api_key=SecretStr("key"))
    providers = VoiceProviderRegistry(settings)
    providers.asr["local"] = FakeAsr()
    providers.tts["piper"] = FakeTts()
    providers.llm["glm"] = RegistryLlm()
    await providers.select(VoiceProviderSelection(asr="local", tts="piper", llm="glm"))
    service = VoiceAgentService(settings, providers=providers)

    result = await service.process(b"pcm", node_id="node-1", turn_id="turn-registry")

    assert result.reply == "今天是星期日。"
    status = providers.status()
    assert status["providers"]["asr"][1]["state"] == "healthy"
    assert status["providers"]["tts"][1]["state"] == "healthy"
    assert status["providers"]["llm"][0]["state"] == "healthy"


@pytest.mark.asyncio
async def test_voice_agent_streams_llm_sentences_into_pcm_before_completion(
    tmp_path: Path,
) -> None:
    settings = Settings(data_dir=tmp_path, voice_glm_api_key=SecretStr("key"))
    providers = VoiceProviderRegistry(settings)
    providers.asr["local"] = FakeAsr()
    providers.tts["piper"] = StreamingTts()
    providers.llm["glm"] = StreamingRegistryLlm()
    await providers.select(VoiceProviderSelection(asr="local", tts="piper", llm="glm"))
    service = VoiceAgentService(settings, providers=providers)
    events: list[object] = []

    async def emit(event: object) -> None:
        events.append(event)

    result = await service.process_stream(
        b"pcm",
        node_id="node-1",
        turn_id="turn-stream",
        emit=emit,
    )

    assert result.reply == "今天是星期日。"
    assert isinstance(events[0], VoiceTranscriptEvent)
    assert isinstance(events[1], VoiceAudioStartEvent)
    assert [event.data for event in events if isinstance(event, VoiceAudioChunkEvent)] == [
        b"pcm-1",
        b"pcm-2",
    ]


@pytest.mark.asyncio
async def test_voice_agent_streams_silence_retry_without_calling_llm(tmp_path: Path) -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(500)

    settings = Settings(data_dir=tmp_path, voice_glm_api_key=SecretStr("key"))
    tts = FixedReplyStreamingTts()
    agent = CodingAgentProvider(settings, transport=httpx.MockTransport(handler))
    service = VoiceAgentService(settings, asr=SilentAsr(), tts=tts, agent=agent)
    events: list[object] = []

    async def emit(event: object) -> None:
        events.append(event)

    result = await service.process_stream(
        b"pcm",
        node_id="node-1",
        turn_id="turn-silent",
        emit=emit,
    )

    assert result.reply == "我没有听清，请再说一次。"
    assert tts.texts == [result.reply]
    assert requests == []
    assert isinstance(events[0], VoiceTranscriptEvent)
    assert isinstance(events[1], VoiceAudioStartEvent)
    assert isinstance(events[2], VoiceAudioChunkEvent)


@pytest.mark.asyncio
async def test_voice_agent_starts_first_sentence_tts_before_llm_finishes(tmp_path: Path) -> None:
    first_sentence_started = asyncio.Event()
    settings = Settings(data_dir=tmp_path, voice_glm_api_key=SecretStr("key"))
    providers = VoiceProviderRegistry(settings)
    tts = GatedStreamingTts(first_sentence_started)
    providers.asr["local"] = FakeAsr()
    providers.tts["piper"] = tts
    providers.llm["glm"] = GatedStreamingLlm(first_sentence_started)
    await providers.select(VoiceProviderSelection(asr="local", tts="piper", llm="glm"))
    service = VoiceAgentService(settings, providers=providers)
    events: list[object] = []

    async def emit(event: object) -> None:
        events.append(event)

    result = await service.process_stream(
        b"pcm",
        node_id="node-1",
        turn_id="turn-gated",
        emit=emit,
    )

    assert first_sentence_started.is_set()
    assert tts.texts == ["第一句。", "第二句。"]
    assert result.reply == "第一句。第二句。"
    assert len([event for event in events if isinstance(event, VoiceAudioStartEvent)]) == 1
