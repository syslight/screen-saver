from __future__ import annotations

import asyncio
import base64
import binascii
import gzip
import io
import json
import logging
import struct
import uuid
import wave
from collections.abc import AsyncIterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

import httpx

from home_agent.config import Settings

logger = logging.getLogger(__name__)


class SpeechRecognizer(Protocol):
    async def transcribe(self, pcm: bytes) -> str: ...


class SpeechSynthesizer(Protocol):
    async def synthesize(self, text: str) -> bytes: ...


@dataclass(frozen=True)
class PcmAudioChunk:
    data: bytes
    sample_rate: int
    channels: int = 1


class StreamingSpeechRecognitionSession(Protocol):
    async def send_audio(self, pcm: bytes) -> None: ...

    async def finish(self) -> str: ...

    async def abort(self) -> None: ...


class LocalFasterWhisperAsr:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._model: Any = None
        self._lock = asyncio.Lock()

    async def transcribe(self, pcm: bytes) -> str:
        async with self._lock:
            return await asyncio.to_thread(self._transcribe_sync, pcm)

    def _transcribe_sync(self, pcm: bytes) -> str:
        if self._model is None:
            from faster_whisper import WhisperModel  # type: ignore[import-untyped]

            self._model = WhisperModel(
                self.settings.voice_asr_model,
                device=self.settings.voice_asr_device,
                compute_type=self.settings.voice_asr_compute_type,
                cpu_threads=self.settings.voice_asr_cpu_threads,
                num_workers=1,
                download_root=str(self.settings.data_dir / "models" / "faster-whisper"),
            )
        segments, _info = self._model.transcribe(
            io.BytesIO(pcm_to_wav(pcm)),
            language=(
                None
                if self.settings.voice_asr_language == "auto"
                else self.settings.voice_asr_language
            ),
            beam_size=1,
            vad_filter=True,
            condition_on_previous_text=False,
        )
        return "".join(str(segment.text) for segment in segments).strip()


class LocalPiperTts:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._tts: Any = None
        self._lock = asyncio.Lock()

    async def synthesize(self, text: str) -> bytes:
        async with self._lock:
            return await asyncio.to_thread(self._synthesize_sync, text)

    def _synthesize_sync(self, text: str) -> bytes:
        if self._tts is None:
            self._tts = self._load_model(
                self.settings.voice_tts_model_dir,
                self.settings.voice_tts_model_name,
            )
        output = io.BytesIO()
        from piper.config import SynthesisConfig

        synthesis = SynthesisConfig(
            speaker_id=self.settings.voice_tts_speaker_id,
            length_scale=1 / self.settings.voice_tts_speed,
            volume=self.settings.voice_tts_volume,
        )
        with wave.open(output, "wb") as target:
            self._tts.synthesize_wav(text, target, syn_config=synthesis)
        return output.getvalue()

    @staticmethod
    def _load_model(model_dir: Path, model_name: str) -> Any:
        from piper import PiperVoice

        required = {
            "model": model_dir / f"{model_name}.onnx",
            "config": model_dir / f"{model_name}.onnx.json",
        }
        missing = [str(path) for path in required.values() if not path.is_file()]
        if missing:
            raise RuntimeError(f"Local TTS model is incomplete: {', '.join(missing)}")
        return PiperVoice.load(
            str(required["model"]),
            config_path=str(required["config"]),
            use_cuda=False,
        )


class OpenAiSpeechRecognizer:
    """OpenAI-compatible transcription endpoint."""

    def __init__(
        self,
        settings: Settings,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.settings = settings
        self.transport = transport

    @property
    def configured(self) -> bool:
        key = self.settings.voice_openai_api_key
        return key is not None and bool(key.get_secret_value().strip())

    async def transcribe(self, pcm: bytes) -> str:
        key = self.settings.voice_openai_api_key
        if key is None or not key.get_secret_value().strip():
            raise RuntimeError("OpenAI ASR credentials are not configured")
        async with httpx.AsyncClient(
            base_url=self.settings.voice_openai_base_url.rstrip("/") + "/",
            timeout=self.settings.voice_timeout_seconds,
            transport=self.transport,
        ) as client:
            response = await client.post(
                "audio/transcriptions",
                headers={"Authorization": f"Bearer {key.get_secret_value()}"},
                data={
                    "model": self.settings.voice_openai_asr_model,
                    "language": self.settings.voice_openai_asr_language,
                    "response_format": "json",
                },
                files={"file": ("audio.wav", pcm_to_wav(pcm), "audio/wav")},
            )
            response.raise_for_status()
        return str(response.json().get("text", "")).strip()


class OpenAiSpeechSynthesizer:
    """OpenAI-compatible speech endpoint returning WAV audio."""

    def __init__(
        self,
        settings: Settings,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.settings = settings
        self.transport = transport

    @property
    def configured(self) -> bool:
        key = self.settings.voice_openai_api_key
        return key is not None and bool(key.get_secret_value().strip())

    async def synthesize(self, text: str) -> bytes:
        key = self.settings.voice_openai_api_key
        if key is None or not key.get_secret_value().strip():
            raise RuntimeError("OpenAI TTS credentials are not configured")
        async with httpx.AsyncClient(
            base_url=self.settings.voice_openai_base_url.rstrip("/") + "/",
            timeout=self.settings.voice_timeout_seconds,
            transport=self.transport,
        ) as client:
            response = await client.post(
                "audio/speech",
                headers={"Authorization": f"Bearer {key.get_secret_value()}"},
                json={
                    "model": self.settings.voice_openai_tts_model,
                    "voice": self.settings.voice_openai_tts_voice,
                    "input": text,
                    "response_format": "wav",
                    "speed": self.settings.voice_openai_tts_speed,
                },
            )
            response.raise_for_status()
        if not response.content:
            raise RuntimeError("OpenAI TTS returned no audio")
        return response.content

    async def stream_pcm(self, text: str) -> AsyncIterator[PcmAudioChunk]:
        key = self.settings.voice_openai_api_key
        if key is None or not key.get_secret_value().strip():
            raise RuntimeError("OpenAI TTS credentials are not configured")
        async with httpx.AsyncClient(
            base_url=self.settings.voice_openai_base_url.rstrip("/") + "/",
            timeout=self.settings.voice_timeout_seconds,
            transport=self.transport,
        ) as client:
            async with client.stream(
                "POST",
                "audio/speech",
                headers={"Authorization": f"Bearer {key.get_secret_value()}"},
                json={
                    "model": self.settings.voice_openai_tts_model,
                    "voice": self.settings.voice_openai_tts_voice,
                    "input": text,
                    "response_format": "pcm",
                    "speed": self.settings.voice_openai_tts_speed,
                },
            ) as response:
                response.raise_for_status()
                received = False
                async for data in response.aiter_bytes(chunk_size=4800):
                    if data:
                        received = True
                        yield PcmAudioChunk(data=data, sample_rate=24000)
                if not received:
                    raise RuntimeError("OpenAI TTS returned no audio")


class VolcanoStreamingAsr:
    """火山 ASR 2.0 优化版双向流式 WebSocket 客户端。"""

    _full_client_request = 0x1
    _audio_only_request = 0x2
    _full_server_response = 0x9
    _error_response = 0xF
    _positive_sequence = 0x1
    _negative_sequence = 0x3

    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    @property
    def configured(self) -> bool:
        direct_key = self.settings.voice_volcano_api_key
        access_token = self.settings.voice_volcano_access_token
        if self.settings.voice_volcano_asr_auth_mode == "app_key":
            return bool(direct_key is not None and direct_key.get_secret_value().strip())
        return bool(
            self.settings.voice_volcano_app_id.strip()
            and access_token is not None
            and access_token.get_secret_value().strip()
        )

    def _auth_headers(self) -> dict[str, str]:
        if not self.configured:
            raise RuntimeError("Volcano ASR credentials are not configured")
        if self.settings.voice_volcano_asr_auth_mode == "app_key":
            api_key = self.settings.voice_volcano_api_key
            assert api_key is not None
            return {"X-Api-Key": api_key.get_secret_value()}
        access_token = self.settings.voice_volcano_access_token
        assert access_token is not None
        return {
            "X-Api-App-Key": self.settings.voice_volcano_app_id,
            "X-Api-Access-Key": access_token.get_secret_value(),
        }

    async def open_stream(self) -> VolcanoAsrSession:
        if not self.configured:
            raise RuntimeError("Volcano ASR credentials are not configured")
        import websockets

        connect_id = str(uuid.uuid4())
        headers = {
            "X-Api-Resource-Id": self.settings.voice_volcano_asr_resource_id,
            "X-Api-Connect-Id": connect_id,
            "X-Api-Request-Id": connect_id,
        }
        headers.update(self._auth_headers())
        websocket = await websockets.connect(
            self.settings.voice_volcano_asr_ws_url,
            additional_headers=headers,
            open_timeout=self.settings.voice_timeout_seconds,
            close_timeout=5,
            max_size=16 * 1024 * 1024,
        )
        payload = json.dumps(
            {
                "user": {"uid": "smart-frame"},
                "audio": {
                    "format": "pcm",
                    "codec": "raw",
                    "rate": 16_000,
                    "bits": 16,
                    "channel": 1,
                },
                "request": {
                    "model_name": self.settings.voice_volcano_asr_model,
                    "language": self.settings.voice_volcano_asr_language,
                    "enable_nonstream": True,
                    "enable_itn": True,
                    "enable_punc": True,
                    "enable_ddc": True,
                    "show_utterances": True,
                },
            },
            ensure_ascii=False,
        ).encode()
        await websocket.send(self._request_frame(payload))
        return VolcanoAsrSession(self, websocket)

    async def transcribe(self, pcm: bytes) -> str:
        session = await self.open_stream()
        try:
            size = self.settings.voice_volcano_asr_chunk_bytes
            for offset in range(0, len(pcm), size):
                await session.send_audio(pcm[offset : offset + size])
            return await session.finish()
        except BaseException:
            await session.abort()
            raise

    @classmethod
    def _request_frame(cls, payload: bytes) -> bytes:
        compressed = gzip.compress(payload)
        header = bytes([0x11, (cls._full_client_request << 4) | 0x1, 0x11, 0])
        return header + struct.pack(">ii", 1, len(compressed)) + compressed

    @classmethod
    def _audio_frame(cls, sequence: int, payload: bytes) -> bytes:
        compressed = gzip.compress(payload)
        flag = cls._negative_sequence if sequence < 0 else cls._positive_sequence
        header = bytes([0x11, (cls._audio_only_request << 4) | flag, 0x01, 0])
        return header + struct.pack(">ii", sequence, len(compressed)) + compressed

    @classmethod
    def _parse_response(cls, message: object) -> tuple[bool, dict[str, Any]]:
        if not isinstance(message, bytes) or len(message) < 4:
            raise RuntimeError("Volcano ASR returned an invalid frame")
        header_size = (message[0] & 0x0F) * 4
        message_type = message[1] >> 4
        flags = message[1] & 0x0F
        compression = message[2] & 0x0F
        offset = header_size
        if flags & 0x1:
            if offset + 4 > len(message):
                raise RuntimeError("Volcano ASR response is missing a sequence")
            offset += 4
        if message_type == cls._error_response:
            if offset + 8 > len(message):
                raise RuntimeError("Volcano ASR returned an invalid error frame")
            error_code, payload_size = struct.unpack(">II", message[offset : offset + 8])
            offset += 8
            raise RuntimeError(f"Volcano ASR rejected the request ({error_code})")
        if message_type != cls._full_server_response or offset + 4 > len(message):
            return bool(flags & 0x2), {}
        payload_size = struct.unpack(">I", message[offset : offset + 4])[0]
        offset += 4
        payload = message[offset : offset + payload_size]
        if len(payload) != payload_size:
            raise RuntimeError("Volcano ASR response payload is truncated")
        if compression == 0x1:
            payload = gzip.decompress(payload)
        try:
            decoded = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise RuntimeError("Volcano ASR returned invalid JSON") from error
        if not isinstance(decoded, dict):
            raise RuntimeError("Volcano ASR returned an invalid result")
        return bool(flags & 0x2), decoded


class VolcanoAsrSession:
    def __init__(self, provider: VolcanoStreamingAsr, websocket: Any) -> None:
        self.provider = provider
        self.websocket = websocket
        self._sequence = 2
        self._closed = False
        self._receiver = asyncio.create_task(self._receive())

    async def send_audio(self, pcm: bytes) -> None:
        if self._closed or not pcm:
            return
        await self.websocket.send(self.provider._audio_frame(self._sequence, pcm))
        self._sequence += 1

    async def finish(self) -> str:
        if self._closed:
            raise RuntimeError("Volcano ASR stream is already closed")
        await self.websocket.send(self.provider._audio_frame(-self._sequence, b""))
        try:
            return await asyncio.wait_for(
                self._receiver, timeout=self.provider.settings.voice_timeout_seconds
            )
        finally:
            self._closed = True
            await self.websocket.close()

    async def abort(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._receiver.cancel()
        await self.websocket.close()

    async def _receive(self) -> str:
        latest = ""
        while True:
            message = await self.websocket.recv()
            is_last, payload = self.provider._parse_response(message)
            result = payload.get("result")
            if isinstance(result, dict):
                text = result.get("text")
                if isinstance(text, str) and text.strip():
                    latest = text.strip()
                elif isinstance(result.get("utterances"), list):
                    utterances = result["utterances"]
                    joined = "".join(
                        str(item.get("text", "")) for item in utterances if isinstance(item, dict)
                    ).strip()
                    if joined:
                        latest = joined
            if is_last:
                return latest


class VolcanoUnidirectionalTts:
    """火山 V3 单向 HTTP 流式 TTS，逐行解码 Base64 PCM。"""

    def __init__(
        self,
        settings: Settings,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.settings = settings
        self.transport = transport

    @property
    def configured(self) -> bool:
        key = self.settings.voice_volcano_api_key
        return bool(key is not None and key.get_secret_value().strip())

    async def synthesize(self, text: str) -> bytes:
        chunks = [chunk.data async for chunk in self.stream_pcm(text)]
        return pcm_to_wav(b"".join(chunks), sample_rate=self.settings.voice_volcano_sample_rate)

    async def stream_pcm(self, text: str) -> AsyncIterator[PcmAudioChunk]:
        key = self.settings.voice_volcano_api_key
        if not self.configured or key is None:
            raise RuntimeError("Volcano TTS credentials are not configured")
        headers = {
            "X-Api-Key": key.get_secret_value(),
            "X-Api-Resource-Id": self.settings.voice_volcano_resource_id,
        }
        received = False
        finished = False
        timeout = httpx.Timeout(self.settings.voice_timeout_seconds)
        async with httpx.AsyncClient(
            transport=self.transport,
            timeout=timeout,
            trust_env=False,
        ) as client:
            async with client.stream(
                "POST",
                self.settings.voice_volcano_tts_url,
                headers=headers,
                json=self._payload(text),
            ) as response:
                response.raise_for_status()
                async for line in response.aiter_lines():
                    if not line.strip():
                        continue
                    event = self._parse_event(line)
                    code = event.get("code")
                    if code == 0:
                        encoded = event.get("data")
                        if isinstance(encoded, str) and encoded:
                            try:
                                payload = base64.b64decode(encoded, validate=True)
                            except (ValueError, binascii.Error) as error:
                                raise RuntimeError(
                                    "Volcano TTS returned invalid audio data"
                                ) from error
                            if payload:
                                received = True
                                yield PcmAudioChunk(
                                    data=payload,
                                    sample_rate=self.settings.voice_volcano_sample_rate,
                                )
                    elif code == 20_000_000:
                        finished = True
                    else:
                        raise RuntimeError("Volcano TTS returned an error status")
        if not received:
            raise RuntimeError("Volcano TTS returned no audio")
        if not finished:
            raise RuntimeError("Volcano TTS response ended before completion")

    def _payload(self, text: str) -> dict[str, object]:
        return {
            "req_params": {
                "text": text,
                "speaker": self.settings.voice_volcano_voice,
                "audio_params": {
                    "format": "pcm",
                    "sample_rate": self.settings.voice_volcano_sample_rate,
                    "speech_rate": self.settings.voice_volcano_speech_rate,
                    "loudness_rate": self.settings.voice_volcano_loudness_rate,
                },
                "additions": json.dumps(
                    {
                        "disable_markdown_filter": True,
                        "enable_language_detector": True,
                        "enable_latex_tn": True,
                        "disable_default_bit_rate": True,
                        "max_length_to_filter_parenthesis": 0,
                        "cache_config": {
                            "text_type": 1,
                            "use_cache": self.settings.voice_volcano_tts_use_cache,
                        },
                        "post_process": {"pitch": self.settings.voice_volcano_pitch_rate},
                    },
                    ensure_ascii=False,
                ),
            }
        }

    @staticmethod
    def _parse_event(line: str) -> dict[str, object]:
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError("Volcano TTS returned invalid JSON") from error
        if not isinstance(event, dict):
            raise RuntimeError("Volcano TTS returned an invalid event")
        return event


class FallbackSpeechSynthesizer:
    def __init__(self, primary: SpeechSynthesizer, fallback: SpeechSynthesizer) -> None:
        self.primary = primary
        self.fallback = fallback

    async def synthesize(self, text: str) -> bytes:
        try:
            return await self.primary.synthesize(text)
        except Exception as error:
            logger.warning("primary TTS failed; using local fallback: %s", type(error).__name__)
            return await self.fallback.synthesize(text)


def pcm_to_wav(pcm: bytes, *, sample_rate: int = 16_000) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        target.setframerate(sample_rate)
        target.writeframes(pcm)
    return output.getvalue()


async def stream_synthesized_pcm(
    synthesizer: SpeechSynthesizer,
    text: str,
    *,
    chunk_bytes: int = 4800,
) -> AsyncIterator[PcmAudioChunk]:
    stream_pcm = getattr(synthesizer, "stream_pcm", None)
    if callable(stream_pcm):
        async for chunk in stream_pcm(text):
            yield chunk
        return
    wav = await synthesizer.synthesize(text)
    with wave.open(io.BytesIO(wav), "rb") as source:
        if source.getsampwidth() != 2 or source.getnchannels() != 1:
            raise RuntimeError("TTS fallback returned unsupported WAV audio")
        sample_rate = source.getframerate()
        while data := source.readframes(max(1, chunk_bytes // 2)):
            yield PcmAudioChunk(data=data, sample_rate=sample_rate)
