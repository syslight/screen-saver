from __future__ import annotations

import asyncio
import base64
import json
from io import BytesIO
from pathlib import Path
from typing import Annotated, Literal, Protocol

import httpx
from PIL import Image, ImageOps, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from home_agent.config import Settings
from home_agent.domain.models import HomeworkTask, SubmissionAsset
from home_agent.errors import DomainError
from home_agent.services.homework_assets import HomeworkAssetService

PROMPT_VERSION = "homework-inspection-v1"

InspectionStep = Annotated[str, Field(min_length=1, max_length=1_000)]


class InspectionItem(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    location: str = Field(min_length=1, max_length=160)
    issue: str = Field(min_length=1, max_length=2_000)
    hint: str = Field(min_length=1, max_length=2_000)
    similar_example: str = Field(alias="similarExample", min_length=1, max_length=2_000)
    steps: list[InspectionStep] = Field(min_length=1, max_length=20)
    confidence: float = Field(ge=0, le=1)


class InspectionResult(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    image_quality: Literal["clear", "unclear", "incomplete"] = Field(alias="imageQuality")
    summary: str = Field(min_length=1, max_length=5_000)
    confidence: float = Field(ge=0, le=1)
    suggested_decision: Literal["accept", "retry", "review"] = Field(alias="suggestedDecision")
    items: list[InspectionItem] = Field(default_factory=list, max_length=100)


class HomeworkInspector(Protocol):
    async def inspect(
        self,
        task: HomeworkTask,
        assets: list[SubmissionAsset],
        asset_service: HomeworkAssetService,
    ) -> InspectionResult: ...


class InspectionProviderError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class OpenAICompatibleHomeworkInspector:
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
        key = self.settings.homework_model_api_key
        return bool(
            self.settings.homework_model_enabled
            and key is not None
            and key.get_secret_value().strip()
            and self.settings.homework_model_name.strip()
            and self.base_url_host is not None
        )

    @property
    def base_url_host(self) -> str | None:
        try:
            url = httpx.URL(self.settings.homework_model_base_url)
        except Exception:
            return None
        if url.scheme not in {"http", "https"} or not url.host:
            return None
        return url.host.decode() if isinstance(url.host, bytes) else url.host

    async def inspect(
        self,
        task: HomeworkTask,
        assets: list[SubmissionAsset],
        asset_service: HomeworkAssetService,
    ) -> InspectionResult:
        if not self.configured:
            raise InspectionProviderError("homework_model_not_configured")
        if not assets:
            raise InspectionProviderError("submission_images_required")

        image_urls: list[str] = []
        try:
            for asset in assets:
                path = asset_service.resolve(asset.local_path)
                image_urls.append(await asyncio.to_thread(_image_data_url, path))
        except (
            DomainError,
            OSError,
            UnidentifiedImageError,
            Image.DecompressionBombError,
        ) as exc:
            raise InspectionProviderError("invalid_submission_image") from exc

        body = {
            "model": self.settings.homework_model_name,
            "messages": [
                {"role": "system", "content": _system_prompt()},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": _task_prompt(task)},
                        *[
                            {"type": "image_url", "image_url": {"url": image_url}}
                            for image_url in image_urls
                        ],
                    ],
                },
            ],
            "temperature": 0.1,
        }
        key = self.settings.homework_model_api_key
        assert key is not None
        endpoint = self.settings.homework_model_base_url.rstrip("/") + "/chat/completions"
        try:
            async with httpx.AsyncClient(
                transport=self.transport,
                timeout=self.settings.homework_model_timeout_seconds,
            ) as client:
                response = await client.post(
                    endpoint,
                    headers={"Authorization": f"Bearer {key.get_secret_value()}"},
                    json=body,
                )
        except httpx.TimeoutException as exc:
            raise InspectionProviderError("model_timeout") from exc
        except httpx.HTTPError as exc:
            raise InspectionProviderError("model_provider_error") from exc

        if response.status_code in {401, 403}:
            raise InspectionProviderError("model_auth_failed")
        if response.status_code == 429:
            raise InspectionProviderError("model_rate_limited")
        if not response.is_success:
            raise InspectionProviderError("model_provider_error")

        try:
            payload = response.json()
            content = payload["choices"][0]["message"]["content"]
            if not isinstance(content, str):
                raise TypeError
            raw_result = json.loads(_strip_json_fence(content))
            return InspectionResult.model_validate(raw_result)
        except (KeyError, IndexError, TypeError, ValueError, ValidationError) as exc:
            raise InspectionProviderError("invalid_model_output") from exc


def _image_data_url(path: Path) -> str:
    with Image.open(path) as source:
        image = ImageOps.exif_transpose(source).convert("RGB")
        image.thumbnail((2400, 2400))
        output = BytesIO()
        image.save(output, format="JPEG", quality=90, optimize=True)
    encoded = base64.b64encode(output.getvalue()).decode("ascii")
    return f"data:image/jpeg;base64,{encoded}"


def _system_prompt() -> str:
    return """你是家庭作业检查助手。只检查图片中可见的学生作答，并给家长提供复核建议。
必须遵守：
1. 不给出题目的完整答案；只指出问题、给思路、给不同数字或语境的类似例子、分步骤引导。
2. 图片看不清、页码不全或无法确定时必须降低置信度，不得猜测。
3. 输出必须是单个 JSON 对象，不得包含 Markdown 或 JSON 之外的文字。
4. JSON 字段必须严格为：imageQuality、summary、confidence、suggestedDecision、items。
5. imageQuality 只能是 clear/unclear/incomplete；suggestedDecision 只能是 accept/retry/review。
6. items 每项必须严格包含 location、issue、hint、similarExample、steps、confidence。
7. 所有自然语言内容使用简体中文，措辞适合家长阅读并能用于引导孩子。"""


def _task_prompt(task: HomeworkTask) -> str:
    reference = task.reference_answer or "（未提供）"
    rubric = task.rubric or "（未提供）"
    return f"""请检查随后的作业图片。
标题：{task.title}
科目：{task.subject}
作业要求：{task.instructions}
家长参考答案（仅用于判断，禁止在输出中完整复述）：{reference}
检查标准：{rubric}
若没有发现明确问题，items 返回空数组。"""


def _strip_json_fence(content: str) -> str:
    text = content.strip()
    if not text.startswith("```"):
        return text
    lines = text.splitlines()
    if len(lines) < 3 or lines[0].strip().lower() not in {"```", "```json"}:
        raise ValueError("invalid JSON fence")
    if lines[-1].strip() != "```":
        raise ValueError("unterminated JSON fence")
    return "\n".join(lines[1:-1]).strip()
