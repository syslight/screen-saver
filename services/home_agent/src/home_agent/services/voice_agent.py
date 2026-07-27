from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import suppress
from dataclasses import dataclass

import httpx

from home_agent.config import Settings
from home_agent.services.coding_agent import CodingAgentProvider
from home_agent.services.local_speech import (
    LocalFasterWhisperAsr,
    LocalPiperTts,
    SpeechRecognizer,
    SpeechSynthesizer,
    StreamingSpeechRecognitionSession,
    stream_synthesized_pcm,
)
from home_agent.services.voice_providers import VoiceProviderRegistry


@dataclass(frozen=True)
class VoiceAgentResult:
    transcript: str
    reply: str
    audio: bytes
    continue_dialog: bool = True


@dataclass(frozen=True)
class VoiceTranscriptEvent:
    transcript: str


@dataclass(frozen=True)
class VoiceAudioStartEvent:
    sample_rate: int
    channels: int
    reply_prefix: str


@dataclass(frozen=True)
class VoiceAudioChunkEvent:
    data: bytes


VoiceAgentStreamEvent = VoiceTranscriptEvent | VoiceAudioStartEvent | VoiceAudioChunkEvent
VoiceAgentStreamEmitter = Callable[[VoiceAgentStreamEvent], Awaitable[None]]


logger = logging.getLogger(__name__)

_EXIT_PHRASES = ("退出对话", "不聊了", "先这样")


class _SentenceBuffer:
    _terminators = frozenset("。！？!?；;\n")

    def __init__(self) -> None:
        self.value = ""

    def add(self, text: str) -> list[str]:
        self.value += text
        ready: list[str] = []
        while self.value:
            boundary = next(
                (index + 1 for index, char in enumerate(self.value) if char in self._terminators),
                None,
            )
            if boundary is None and len(self.value) >= 40:
                boundary = 40
            if boundary is None:
                break
            sentence = self.value[:boundary].strip()
            self.value = self.value[boundary:]
            if sentence:
                ready.append(sentence)
        return ready

    def finish(self) -> str:
        remainder = self.value.strip()
        self.value = ""
        return remainder


class VoiceAgentService:
    def __init__(
        self,
        settings: Settings,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        asr: SpeechRecognizer | None = None,
        tts: SpeechSynthesizer | None = None,
        agent: CodingAgentProvider | None = None,
        providers: VoiceProviderRegistry | None = None,
    ) -> None:
        self.settings = settings
        self.providers = providers
        self.asr = asr or LocalFasterWhisperAsr(settings)
        self.tts = tts or LocalPiperTts(settings)
        self.agent = agent or CodingAgentProvider(settings, transport=transport)

    @property
    def configured(self) -> bool:
        return self.providers.selected_llm.configured if self.providers else self.agent.configured

    async def open_asr_stream(self) -> StreamingSpeechRecognitionSession | None:
        return await self.providers.open_asr_stream() if self.providers else None

    async def process(
        self,
        pcm: bytes,
        *,
        node_id: str,
        turn_id: str,
        asr_stream: StreamingSpeechRecognitionSession | None = None,
    ) -> VoiceAgentResult:
        started_at = time.perf_counter()
        if not self.configured:
            if asr_stream is not None:
                await asr_stream.abort()
            return VoiceAgentResult("", "家庭语音 Agent 尚未配置。", b"", False)
        selection = self.providers.selection if self.providers else None
        asr = self.providers.selected_asr if self.providers else self.asr
        tts = self.providers.selected_tts if self.providers else self.tts
        agent = self.providers.selected_llm if self.providers else self.agent
        try:
            transcript = (
                await asr_stream.finish() if asr_stream is not None else await asr.transcribe(pcm)
            )
        except Exception as error:
            if self.providers and selection is not None:
                self.providers.record_error("asr", selection.asr, error, started_at)
            raise
        asr_done_at = time.perf_counter()
        if self.providers and selection is not None:
            self.providers.record_success("asr", selection.asr, started_at)
        continue_dialog = True
        agent_called = False
        if not transcript:
            reply = "我没有听清，请再说一次。"
        elif any(phrase in transcript for phrase in _EXIT_PHRASES):
            if self.providers:
                self.providers.clear(node_id)
            else:
                agent.clear(node_id)
            reply = "好的，需要我时叫小方。"
            continue_dialog = False
        else:
            agent_called = True
            try:
                reply = await agent.reply(transcript, node_id=node_id)
            except Exception as error:
                if self.providers and selection is not None:
                    self.providers.record_error("llm", selection.llm, error, asr_done_at)
                raise
        agent_done_at = time.perf_counter()
        if self.providers and selection is not None and agent_called:
            self.providers.record_success("llm", selection.llm, asr_done_at)
        try:
            audio = await tts.synthesize(reply)
        except Exception as error:
            if self.providers and selection is not None:
                self.providers.record_error("tts", selection.tts, error, agent_done_at)
            raise
        completed_at = time.perf_counter()
        if self.providers and selection is not None:
            self.providers.record_success("tts", selection.tts, agent_done_at)
        logger.info(
            "voice turn completed node=%s turn=%s asr_ms=%d agent_ms=%d tts_ms=%d total_ms=%d",
            node_id,
            turn_id,
            round((asr_done_at - started_at) * 1000),
            round((agent_done_at - asr_done_at) * 1000),
            round((completed_at - agent_done_at) * 1000),
            round((completed_at - started_at) * 1000),
        )
        return VoiceAgentResult(transcript, reply, audio, continue_dialog)

    async def process_stream(
        self,
        pcm: bytes,
        *,
        node_id: str,
        turn_id: str,
        emit: VoiceAgentStreamEmitter,
        asr_stream: StreamingSpeechRecognitionSession | None = None,
    ) -> VoiceAgentResult:
        started_at = time.perf_counter()
        if not self.configured:
            if asr_stream is not None:
                await asr_stream.abort()
            return VoiceAgentResult("", "家庭语音 Agent 尚未配置。", b"", False)
        selection = self.providers.selection if self.providers else None
        asr = self.providers.selected_asr if self.providers else self.asr
        tts = self.providers.selected_tts if self.providers else self.tts
        agent = self.providers.selected_llm if self.providers else self.agent
        try:
            transcript = (
                await asr_stream.finish() if asr_stream is not None else await asr.transcribe(pcm)
            )
        except Exception as error:
            if self.providers and selection is not None:
                self.providers.record_error("asr", selection.asr, error, started_at)
            raise
        asr_done_at = time.perf_counter()
        if self.providers and selection is not None:
            self.providers.record_success("asr", selection.asr, started_at)
        await emit(VoiceTranscriptEvent(transcript))

        continue_dialog = True
        agent_called = False
        fixed_reply: str | None = None
        if not transcript:
            fixed_reply = "我没有听清，请再说一次。"
        elif any(phrase in transcript for phrase in _EXIT_PHRASES):
            if self.providers:
                self.providers.clear(node_id)
            else:
                agent.clear(node_id)
            fixed_reply = "好的，需要我时叫小方。"
            continue_dialog = False
        else:
            agent_called = True

        sentences: asyncio.Queue[str | None] = asyncio.Queue()
        reply_parts: list[str] = []
        sentence_buffer = _SentenceBuffer()
        first_llm_delta_at: float | None = None

        async def produce_reply() -> None:
            nonlocal first_llm_delta_at
            try:
                if fixed_reply is not None:
                    chunks = _single_text_stream(fixed_reply)
                else:
                    reply_stream = getattr(agent, "reply_stream", None)
                    chunks = (
                        reply_stream(transcript, node_id=node_id)
                        if callable(reply_stream)
                        else _single_text_stream(await agent.reply(transcript, node_id=node_id))
                    )
                async for delta in chunks:
                    if first_llm_delta_at is None:
                        first_llm_delta_at = time.perf_counter()
                    reply_parts.append(delta)
                    for sentence in sentence_buffer.add(delta):
                        await sentences.put(sentence)
                if remainder := sentence_buffer.finish():
                    await sentences.put(remainder)
            finally:
                await sentences.put(None)

        producer = asyncio.create_task(produce_reply())
        audio_started = False
        audio_format: tuple[int, int] | None = None
        first_audio_at: float | None = None
        tts_started_at = time.perf_counter()
        try:
            while (sentence := await sentences.get()) is not None:
                try:
                    async for chunk in stream_synthesized_pcm(tts, sentence):
                        current_format = (chunk.sample_rate, chunk.channels)
                        if audio_format is not None and audio_format != current_format:
                            raise RuntimeError("TTS audio format changed during one response")
                        if not audio_started:
                            audio_started = True
                            audio_format = current_format
                            first_audio_at = time.perf_counter()
                            await emit(
                                VoiceAudioStartEvent(
                                    sample_rate=chunk.sample_rate,
                                    channels=chunk.channels,
                                    reply_prefix="".join(reply_parts).strip(),
                                )
                            )
                        await emit(VoiceAudioChunkEvent(chunk.data))
                except Exception as error:
                    if self.providers and selection is not None:
                        self.providers.record_error("tts", selection.tts, error, tts_started_at)
                    raise
            try:
                await producer
            except Exception as error:
                if self.providers and selection is not None and agent_called:
                    self.providers.record_error("llm", selection.llm, error, asr_done_at)
                raise
        finally:
            if not producer.done():
                producer.cancel()
                with suppress(asyncio.CancelledError):
                    await producer

        completed_at = time.perf_counter()
        reply = "".join(reply_parts).strip()
        if not reply:
            raise ValueError("voice agent returned an empty reply")
        if self.providers and selection is not None:
            if agent_called:
                self.providers.record_success("llm", selection.llm, asr_done_at)
            self.providers.record_success("tts", selection.tts, tts_started_at)
        logger.info(
            "voice stream completed node=%s turn=%s asr_ms=%d llm_first_token_ms=%d "
            "first_audio_ms=%d total_ms=%d",
            node_id,
            turn_id,
            round((asr_done_at - started_at) * 1000),
            round(((first_llm_delta_at or completed_at) - asr_done_at) * 1000),
            round(((first_audio_at or completed_at) - asr_done_at) * 1000),
            round((completed_at - started_at) * 1000),
        )
        return VoiceAgentResult(transcript, reply, b"", continue_dialog)


async def _single_text_stream(text: str) -> AsyncIterator[str]:
    yield text
