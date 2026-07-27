from __future__ import annotations

import asyncio
import json
import time
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Literal

import httpx
from pydantic import SecretStr

from home_agent.config import Settings


@dataclass(frozen=True)
class CodingProviderConfig:
    name: str
    base_url: str
    api_key: SecretStr | None
    model: str
    temperature: float


class CodingAgentProvider:
    """Text-only family Agent backed by an OpenAI-compatible coding endpoint."""

    def __init__(
        self,
        settings: Settings,
        *,
        provider_name: Literal["glm", "kimi"] | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.settings = settings
        self.provider_name = provider_name or settings.voice_agent_provider
        self.transport = transport
        self._history: dict[str, tuple[float, list[dict[str, str]]]] = {}
        self._locks: dict[str, asyncio.Lock] = {}

    _history_ttl_seconds = 5 * 60
    _history_rounds = 6

    @property
    def config(self) -> CodingProviderConfig:
        if self.provider_name == "kimi":
            return CodingProviderConfig(
                name="kimi",
                base_url=self.settings.voice_kimi_base_url,
                api_key=self.settings.voice_kimi_api_key,
                model=self.settings.voice_kimi_model,
                temperature=self.settings.voice_kimi_temperature,
            )
        return CodingProviderConfig(
            name="glm",
            base_url=self.settings.voice_glm_base_url,
            api_key=self.settings.voice_glm_api_key,
            model=self.settings.voice_glm_model,
            temperature=self.settings.voice_glm_temperature,
        )

    @property
    def configured(self) -> bool:
        key = self.config.api_key
        return key is not None and bool(key.get_secret_value().strip())

    async def reply(self, transcript: str, *, node_id: str) -> str:
        chunks = [chunk async for chunk in self.reply_stream(transcript, node_id=node_id)]
        return "".join(chunks).strip()

    async def reply_stream(self, transcript: str, *, node_id: str) -> AsyncIterator[str]:
        lock = self._locks.setdefault(node_id, asyncio.Lock())
        async with lock:
            async for chunk in self._reply_stream_locked(transcript, node_id=node_id):
                yield chunk

    async def health_check(self) -> None:
        config = self.config
        if config.api_key is None or not config.api_key.get_secret_value().strip():
            raise RuntimeError(f"{config.name} credentials are not configured")
        await self._request(
            [
                {"role": "system", "content": "只回答 OK。"},
                {"role": "user", "content": "health check"},
            ],
            max_tokens=4,
        )

    async def _reply_stream_locked(self, transcript: str, *, node_id: str) -> AsyncIterator[str]:
        config = self.config
        if config.api_key is None or not config.api_key.get_secret_value().strip():
            yield "家庭语音 Agent 尚未配置文本模型。"
            return
        now = time.monotonic()
        updated_at, history = self._history.get(node_id, (now, []))
        if now - updated_at > self._history_ttl_seconds:
            history = []
        user_message = {
            "role": "user",
            "content": f"来源设备：{node_id}\n用户说：{transcript}",
        }
        messages = [
            {
                "role": "system",
                "content": (
                    "你是家庭相册语音助手。使用简体中文直接回答，最多两句话。"
                    "不要输出思考过程。不要声称已经控制设备，除非请求结果明确提供成功证据。"
                ),
            },
            *history,
            user_message,
        ]
        parts: list[str] = []
        async for chunk in self._request_stream(messages, max_tokens=256):
            parts.append(chunk)
            yield chunk
        reply = "".join(parts).strip()
        if not reply:
            raise ValueError(f"{config.name} returned an empty reply")
        next_history = [*history, user_message, {"role": "assistant", "content": reply}]
        self._history[node_id] = (
            now,
            next_history[-self._history_rounds * 2 :],
        )

    async def _request_stream(
        self, messages: list[dict[str, str]], *, max_tokens: int
    ) -> AsyncIterator[str]:
        config = self.config
        if config.api_key is None:
            raise RuntimeError(f"{config.name} credentials are not configured")
        body: dict[str, object] = {
            "model": config.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "stream": True,
            "temperature": config.temperature,
        }
        if config.name == "glm":
            body["thinking"] = {"type": "disabled"}
        received = False
        async with httpx.AsyncClient(
            base_url=config.base_url.rstrip("/") + "/",
            timeout=self.settings.voice_timeout_seconds,
            transport=self.transport,
        ) as client:
            async with client.stream(
                "POST",
                "chat/completions",
                headers={"Authorization": f"Bearer {config.api_key.get_secret_value()}"},
                json=body,
            ) as response:
                response.raise_for_status()
                async for line in response.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if not data or data == "[DONE]":
                        continue
                    payload = json.loads(data)
                    choices = payload.get("choices", [])
                    if not choices:
                        continue
                    content = choices[0].get("delta", {}).get("content", "")
                    if isinstance(content, str) and content:
                        received = True
                        yield content
        if not received:
            raise ValueError(f"{config.name} returned no streamed content")

    async def _request(self, messages: list[dict[str, str]], *, max_tokens: int) -> str:
        config = self.config
        if config.api_key is None:
            raise RuntimeError(f"{config.name} credentials are not configured")
        body: dict[str, object] = {
            "model": config.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "stream": False,
            "temperature": config.temperature,
        }
        if config.name == "glm":
            body["thinking"] = {"type": "disabled"}
        async with httpx.AsyncClient(
            base_url=config.base_url.rstrip("/") + "/",
            timeout=self.settings.voice_timeout_seconds,
            transport=self.transport,
        ) as client:
            response = await client.post(
                "chat/completions",
                headers={"Authorization": f"Bearer {config.api_key.get_secret_value()}"},
                json=body,
            )
            response.raise_for_status()
        payload = response.json()
        choices = payload.get("choices", [])
        if not choices:
            raise ValueError(f"{config.name} returned no choices")
        content = choices[0].get("message", {}).get("content", "")
        reply = str(content).strip()
        if not reply:
            raise ValueError(f"{config.name} returned an empty reply")
        return reply

    def clear(self, node_id: str) -> None:
        self._history.pop(node_id, None)
