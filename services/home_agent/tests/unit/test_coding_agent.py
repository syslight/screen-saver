from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest
from pydantic import SecretStr

from home_agent.config import Settings
from home_agent.services.coding_agent import CodingAgentProvider


def streamed_reply(*chunks: str) -> httpx.Response:
    lines = [
        f"data: {json.dumps({'choices': [{'delta': {'content': chunk}}]}, ensure_ascii=False)}"
        for chunk in chunks
    ]
    lines.append("data: [DONE]")
    return httpx.Response(
        200,
        content=("\n\n".join(lines) + "\n\n").encode(),
        headers={"content-type": "text/event-stream"},
    )


@pytest.mark.parametrize(
    ("provider", "expected_path", "has_thinking"),
    [
        ("glm", "/glm/chat/completions", True),
        ("kimi", "/kimi/chat/completions", False),
    ],
)
@pytest.mark.asyncio
async def test_coding_provider_presets_use_openai_chat_completions(
    tmp_path: Path,
    provider: str,
    expected_path: str,
    has_thinking: bool,
) -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return streamed_reply("收", "到。")

    settings = Settings(
        data_dir=tmp_path,
        voice_agent_provider=provider,
        voice_glm_base_url="https://agent.test/glm",
        voice_glm_api_key=SecretStr("glm-key"),
        voice_kimi_base_url="https://agent.test/kimi",
        voice_kimi_api_key=SecretStr("kimi-key"),
        voice_glm_temperature=0.45,
        voice_kimi_temperature=0.65,
    )
    agent = CodingAgentProvider(settings, transport=httpx.MockTransport(handler))

    assert await agent.reply("你好", node_id="node-1") == "收到。"
    assert requests[0].url.path == expected_path
    body = json.loads(requests[0].content)
    assert ("thinking" in body) is has_thinking
    assert body["messages"][1]["content"].startswith("来源设备：node-1")
    assert body["stream"] is True
    assert body["temperature"] == (0.45 if provider == "glm" else 0.65)


@pytest.mark.asyncio
async def test_coding_provider_rejects_empty_response(tmp_path: Path) -> None:
    settings = Settings(data_dir=tmp_path, voice_glm_api_key=SecretStr("key"))
    agent = CodingAgentProvider(
        settings,
        transport=httpx.MockTransport(lambda _request: streamed_reply()),
    )

    with pytest.raises(ValueError, match="no streamed content"):
        await agent.reply("你好", node_id="node-1")


@pytest.mark.asyncio
async def test_coding_provider_health_check_uses_non_streaming_request(tmp_path: Path) -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": "OK"}}]},
        )

    settings = Settings(
        data_dir=tmp_path,
        voice_glm_api_key=SecretStr("key"),
        voice_glm_base_url="https://agent.test/v1",
    )
    agent = CodingAgentProvider(settings, transport=httpx.MockTransport(handler))

    await agent.health_check()

    assert len(requests) == 1
    body = json.loads(requests[0].content)
    assert body["stream"] is False
    assert body["max_tokens"] == 4
    assert body["thinking"] == {"type": "disabled"}


@pytest.mark.asyncio
async def test_coding_provider_keeps_short_context_per_node(tmp_path: Path) -> None:
    bodies: list[dict[str, object]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        bodies.append(json.loads(request.content))
        return streamed_reply("记住了。")

    settings = Settings(data_dir=tmp_path, voice_glm_api_key=SecretStr("key"))
    agent = CodingAgentProvider(settings, transport=httpx.MockTransport(handler))

    await agent.reply("我喜欢蓝色", node_id="node-1")
    await agent.reply("我喜欢什么颜色", node_id="node-1")
    await agent.reply("我是谁", node_id="node-2")

    second_messages = bodies[1]["messages"]
    assert isinstance(second_messages, list)
    assert [message["role"] for message in second_messages] == [
        "system",
        "user",
        "assistant",
        "user",
    ]
    third_messages = bodies[2]["messages"]
    assert isinstance(third_messages, list)
    assert len(third_messages) == 2

    agent.clear("node-1")
    await agent.reply("还记得吗", node_id="node-1")
    cleared_messages = bodies[3]["messages"]
    assert isinstance(cleared_messages, list)
    assert len(cleared_messages) == 2
