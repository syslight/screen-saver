from __future__ import annotations

import json
from datetime import date
from pathlib import Path
from typing import Any

import httpx
import pytest
from PIL import Image
from pydantic import SecretStr

from home_agent.config import Settings
from home_agent.domain.models import HomeworkTask, SubmissionAsset
from home_agent.services.homework_assets import HomeworkAssetService
from home_agent.services.homework_inspector import (
    InspectionProviderError,
    OpenAICompatibleHomeworkInspector,
)


def settings_for_model(tmp_path: Path, **changes: Any) -> Settings:
    values: dict[str, Any] = {
        "data_dir": tmp_path,
        "homework_model_enabled": True,
        "homework_model_api_key": SecretStr("secret-test-key"),
        "homework_model_base_url": "https://api.moonshot.ai/v1/",
        "homework_model_name": "kimi-k3",
    }
    values.update(changes)
    return Settings(**values)


def task_and_asset(tmp_path: Path) -> tuple[HomeworkTask, SubmissionAsset]:
    relative = Path("homework/assets/family/submission/page.png")
    path = tmp_path / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (3200, 1200), color=(245, 245, 245)).save(path)
    task = HomeworkTask(
        id="task-id",
        household_id="family",
        child_id="child-id",
        title="数学练习",
        subject="math",
        task_date=date(2026, 7, 24),
        instructions="完成第 1 至 3 题",
        reference_answer="第一题答案 42",
        rubric="必须写过程",
        created_by="parent-id",
    )
    asset = SubmissionAsset(
        household_id="family",
        submission_id="submission",
        media_type="image/png",
        local_path=relative.as_posix(),
        sha256="0" * 64,
        size_bytes=path.stat().st_size,
    )
    return task, asset


def valid_result(**changes: Any) -> dict[str, Any]:
    result: dict[str, Any] = {
        "imageQuality": "clear",
        "summary": "整体清晰，第 2 题需要家长复核。",
        "confidence": 0.9,
        "suggestedDecision": "retry",
        "items": [
            {
                "location": "第 2 题",
                "issue": "计算过程有一处不一致。",
                "hint": "重新检查进位。",
                "similarExample": "例如计算 18+27 时先看个位。",
                "steps": ["圈出个位", "重新计算"],
                "confidence": 0.88,
            }
        ],
    }
    result.update(changes)
    return result


@pytest.mark.asyncio
async def test_openai_compatible_request_preprocesses_image_and_parses_result(
    tmp_path: Path,
) -> None:
    captured: dict[str, Any] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["authorization"] = request.headers["Authorization"]
        captured["body"] = json.loads(request.content)
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": json.dumps(valid_result())}}]},
        )

    settings = settings_for_model(tmp_path)
    task, asset = task_and_asset(tmp_path)
    inspector = OpenAICompatibleHomeworkInspector(settings, transport=httpx.MockTransport(handler))

    result = await inspector.inspect(task, [asset], HomeworkAssetService(settings))

    assert inspector.configured is True
    assert inspector.base_url_host == "api.moonshot.ai"
    assert result.image_quality == "clear"
    assert result.items[0].similar_example.startswith("例如")
    assert captured["url"] == "https://api.moonshot.ai/v1/chat/completions"
    assert captured["authorization"] == "Bearer secret-test-key"
    body = captured["body"]
    assert body["model"] == "kimi-k3"
    assert "response_format" not in body
    assert "thinking" not in body
    assert "禁止在输出中完整复述" in body["messages"][1]["content"][0]["text"]
    assert body["messages"][1]["content"][1]["image_url"]["url"].startswith(
        "data:image/jpeg;base64,"
    )


@pytest.mark.asyncio
async def test_accepts_plain_or_strictly_fenced_json(tmp_path: Path) -> None:
    task, asset = task_and_asset(tmp_path)
    settings = settings_for_model(tmp_path)

    def handler(_request: httpx.Request) -> httpx.Response:
        content = "```json\n" + json.dumps(valid_result(items=[])) + "\n```"
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

    inspector = OpenAICompatibleHomeworkInspector(settings, transport=httpx.MockTransport(handler))
    result = await inspector.inspect(task, [asset], HomeworkAssetService(settings))
    assert result.items == []


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("status", "code"),
    [
        (401, "model_auth_failed"),
        (403, "model_auth_failed"),
        (429, "model_rate_limited"),
        (500, "model_provider_error"),
    ],
)
async def test_maps_provider_http_errors(tmp_path: Path, status: int, code: str) -> None:
    task, asset = task_and_asset(tmp_path)
    settings = settings_for_model(tmp_path)
    transport = httpx.MockTransport(lambda _request: httpx.Response(status, text="sensitive"))
    inspector = OpenAICompatibleHomeworkInspector(settings, transport=transport)
    with pytest.raises(InspectionProviderError, match=code) as caught:
        await inspector.inspect(task, [asset], HomeworkAssetService(settings))
    assert caught.value.code == code
    assert "sensitive" not in str(caught.value)


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "content",
    [
        "not-json",
        "text before {}",
        "```json\n{}",
        json.dumps(valid_result(extra="not allowed")),
        json.dumps({**valid_result(), "confidence": 2}),
    ],
)
async def test_rejects_invalid_or_non_schema_model_output(tmp_path: Path, content: str) -> None:
    task, asset = task_and_asset(tmp_path)
    settings = settings_for_model(tmp_path)
    transport = httpx.MockTransport(
        lambda _request: httpx.Response(200, json={"choices": [{"message": {"content": content}}]})
    )
    inspector = OpenAICompatibleHomeworkInspector(settings, transport=transport)
    with pytest.raises(InspectionProviderError, match="invalid_model_output"):
        await inspector.inspect(task, [asset], HomeworkAssetService(settings))


@pytest.mark.asyncio
async def test_configuration_timeout_network_and_missing_images_are_safe(tmp_path: Path) -> None:
    task, asset = task_and_asset(tmp_path)
    disabled = settings_for_model(tmp_path, homework_model_enabled=False)
    invalid_url = settings_for_model(tmp_path, homework_model_base_url="file:///tmp/model")
    assert OpenAICompatibleHomeworkInspector(disabled).configured is False
    assert OpenAICompatibleHomeworkInspector(invalid_url).base_url_host is None

    with pytest.raises(InspectionProviderError, match="homework_model_not_configured"):
        await OpenAICompatibleHomeworkInspector(disabled).inspect(
            task, [asset], HomeworkAssetService(disabled)
        )

    settings = settings_for_model(tmp_path)
    with pytest.raises(InspectionProviderError, match="submission_images_required"):
        await OpenAICompatibleHomeworkInspector(settings).inspect(
            task, [], HomeworkAssetService(settings)
        )

    def timeout(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("late", request=request)

    with pytest.raises(InspectionProviderError, match="model_timeout"):
        await OpenAICompatibleHomeworkInspector(
            settings, transport=httpx.MockTransport(timeout)
        ).inspect(task, [asset], HomeworkAssetService(settings))

    def network(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("offline", request=request)

    with pytest.raises(InspectionProviderError, match="model_provider_error"):
        await OpenAICompatibleHomeworkInspector(
            settings, transport=httpx.MockTransport(network)
        ).inspect(task, [asset], HomeworkAssetService(settings))


@pytest.mark.asyncio
async def test_missing_local_image_and_non_string_content_are_rejected(tmp_path: Path) -> None:
    task, asset = task_and_asset(tmp_path)
    settings = settings_for_model(tmp_path)
    (tmp_path / asset.local_path).unlink()
    inspector = OpenAICompatibleHomeworkInspector(settings)
    with pytest.raises(InspectionProviderError, match="invalid_submission_image"):
        await inspector.inspect(task, [asset], HomeworkAssetService(settings))

    _task, replacement = task_and_asset(tmp_path)
    transport = httpx.MockTransport(
        lambda _request: httpx.Response(200, json={"choices": [{"message": {"content": []}}]})
    )
    with pytest.raises(InspectionProviderError, match="invalid_model_output"):
        await OpenAICompatibleHomeworkInspector(settings, transport=transport).inspect(
            task, [replacement], HomeworkAssetService(settings)
        )
