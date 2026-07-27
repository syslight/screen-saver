from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest
from pydantic import SecretStr
from websockets.datastructures import Headers
from websockets.exceptions import InvalidStatus
from websockets.http11 import Response

from home_agent.config import Settings
from home_agent.services.voice_providers import (
    VoiceProviderRegistry,
    VoiceProviderSelection,
    _provider_error_message,
    provider_kind,
)


def _configured_settings(tmp_path: Path) -> Settings:
    model_dir = tmp_path / "piper"
    model_dir.mkdir(exist_ok=True)
    (model_dir / "voice.onnx").write_bytes(b"model")
    (model_dir / "voice.onnx.json").write_text("{}", encoding="utf-8")
    return Settings(
        data_dir=tmp_path,
        voice_tts_model_dir=model_dir,
        voice_tts_model_name="voice",
        voice_openai_api_key=SecretStr("openai-secret"),
        voice_volcano_app_id="app-id",
        voice_volcano_api_key=SecretStr("volcano-api-secret"),
        voice_volcano_access_token=SecretStr("volcano-secret"),
        voice_glm_api_key=SecretStr("glm-secret"),
        voice_kimi_api_key=SecretStr("kimi-secret"),
    )


def test_provider_registry_defaults_to_volcano_without_exposing_secrets(tmp_path: Path) -> None:
    registry = VoiceProviderRegistry(_configured_settings(tmp_path))
    status = registry.status()

    assert status["selection"] == {"asr": "volcano", "tts": "volcano", "llm": "glm"}
    assert "volcano-secret" not in json.dumps(status)
    assert "volcano-api-secret" not in json.dumps(status)
    asr = status["providers"]["asr"]
    assert asr[0]["name"] == "volcano"
    assert asr[0]["streaming"] is True
    assert asr[0]["state"] == "ready"


@pytest.mark.asyncio
async def test_provider_selection_is_persisted_with_private_permissions(tmp_path: Path) -> None:
    settings = _configured_settings(tmp_path)
    registry = VoiceProviderRegistry(settings)
    selection = VoiceProviderSelection(asr="local", tts="piper", llm="kimi")

    await registry.select(selection)

    assert registry.selection == selection
    assert registry.selection_path.stat().st_mode & 0o777 == 0o600
    assert VoiceProviderRegistry(settings).selection == selection


@pytest.mark.asyncio
async def test_provider_registry_rejects_unknown_provider_and_records_health(
    tmp_path: Path,
) -> None:
    registry = VoiceProviderRegistry(_configured_settings(tmp_path))
    with pytest.raises(ValueError, match="unknown asr"):
        await registry.select(VoiceProviderSelection(asr="bad", tts="piper", llm="glm"))
    assert provider_kind("tts") == "tts"
    with pytest.raises(ValueError, match="unknown provider kind"):
        provider_kind("image")

    registry.record_success("asr", "volcano", 0, "正常")
    status = registry.status()
    assert status["providers"]["asr"][0]["state"] == "healthy"
    registry.record_error("asr", "volcano", RuntimeError("must-not-leak"), 0)
    status = registry.status()
    encoded = json.dumps(status, ensure_ascii=False)
    assert status["providers"]["asr"][0]["state"] == "error"
    assert "must-not-leak" not in encoded


def test_provider_registry_reports_actionable_volcano_auth_errors(tmp_path: Path) -> None:
    registry = VoiceProviderRegistry(_configured_settings(tmp_path))
    response = Response(
        401,
        "Unauthorized",
        Headers(),
        body=b'{"error":"Invalid X-Api-Key","private":"must-not-leak"}',
    )

    registry.record_error("asr", "volcano", InvalidStatus(response), 0)

    status = registry.status()["providers"]["asr"][0]
    assert status["message"] == (
        "鉴权失败：APP Key 无效；请复制当前豆包语音项目 API Key 页面中的 APP Key"
    )
    assert "must-not-leak" not in json.dumps(status, ensure_ascii=False)


@pytest.mark.parametrize(
    ("error", "expected"),
    (
        (
            InvalidStatus(
                Response(
                    401,
                    "Unauthorized",
                    Headers(),
                    body=b'{"error":"requested grant not found in SaaS storage"}',
                )
            ),
            "旧版应用未开通",
        ),
        (
            httpx.HTTPStatusError(
                "forbidden",
                request=httpx.Request("GET", "https://provider.invalid"),
                response=httpx.Response(403),
            ),
            "没有调用权限",
        ),
        (
            httpx.HTTPStatusError(
                "limited",
                request=httpx.Request("GET", "https://provider.invalid"),
                response=httpx.Response(429),
            ),
            "调用受限",
        ),
        (httpx.ReadTimeout("slow"), "调用超时"),
        (httpx.ConnectError("offline"), "连接失败"),
    ),
)
def test_provider_error_messages_are_safe_and_actionable(
    error: BaseException, expected: str
) -> None:
    message = _provider_error_message("asr", "volcano", error)
    assert expected in message
    assert str(error) not in message


def test_invalid_persisted_selection_falls_back_to_environment(tmp_path: Path) -> None:
    (tmp_path / "voice-providers.json").write_text('{"asr":"invalid"}', encoding="utf-8")
    registry = VoiceProviderRegistry(Settings(data_dir=tmp_path))
    assert registry.selection == VoiceProviderSelection(asr="volcano", tts="volcano", llm="glm")


class FakeAsr:
    configured = True

    async def transcribe(self, pcm: bytes) -> str:
        assert pcm
        return ""


class FakeTts:
    configured = True

    async def synthesize(self, text: str) -> bytes:
        assert text
        return b"wav"


class FakeLlm:
    configured = True
    config = SimpleNamespace(model="fake-model")

    async def health_check(self) -> None:
        return None

    def clear(self, node_id: str) -> None:
        assert node_id


@pytest.mark.asyncio
async def test_provider_registry_checks_each_remote_kind(tmp_path: Path) -> None:
    registry = VoiceProviderRegistry(_configured_settings(tmp_path))
    registry.asr["openai"] = FakeAsr()
    registry.tts["openai"] = FakeTts()
    registry.llm["kimi"] = FakeLlm()

    assert (await registry.check("asr", "openai"))["state"] == "healthy"
    assert (await registry.check("tts", "openai"))["state"] == "healthy"
    assert (await registry.check("llm", "kimi"))["state"] == "healthy"
    assert registry.selected_asr is registry.asr["volcano"]
    assert registry.selected_tts is registry.tts["volcano"]
    assert registry.selected_llm is registry.llm["glm"]


@pytest.mark.asyncio
async def test_provider_registry_opens_selected_volcano_stream(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    registry = VoiceProviderRegistry(_configured_settings(tmp_path))
    provider = registry.asr["volcano"]
    session = object()
    monkeypatch.setattr(provider, "open_stream", AsyncMock(return_value=session))

    assert await registry.open_asr_stream() is session
    assert registry.status()["providers"]["asr"][0]["state"] == "healthy"
    await registry.select(VoiceProviderSelection(asr="local", tts="piper", llm="glm"))
    assert await registry.open_asr_stream() is None


@pytest.mark.asyncio
async def test_provider_registry_rejects_unconfigured_check(tmp_path: Path) -> None:
    registry = VoiceProviderRegistry(Settings(data_dir=tmp_path))
    with pytest.raises(ValueError, match="not configured"):
        await registry.check("tts", "openai")


def test_legacy_auto_tts_prefers_configured_volcano(tmp_path: Path) -> None:
    settings = _configured_settings(tmp_path)
    settings.voice_tts_provider = "auto"
    assert VoiceProviderRegistry(settings).selection.tts == "volcano"


@pytest.mark.asyncio
async def test_managed_credentials_persist_privately_and_override_environment(
    tmp_path: Path,
) -> None:
    settings = _configured_settings(tmp_path)
    registry = VoiceProviderRegistry(settings)

    await registry.update_credentials(
        {"openaiApiKey": "managed-openai", "volcanoAppId": "managed-app"},
        {"kimiApiKey"},
    )

    assert registry.credentials.path.stat().st_mode & 0o777 == 0o600
    encoded = json.dumps(registry.status(), ensure_ascii=False)
    assert "managed-openai" not in encoded
    assert "managed-app" not in encoded
    restored = VoiceProviderRegistry(_configured_settings(tmp_path))
    status = restored.status()
    openai_asr = next(item for item in status["providers"]["asr"] if item["name"] == "openai")
    openai_key = next(item for item in openai_asr["fields"] if item["name"] == "apiKey")
    kimi = next(item for item in status["providers"]["llm"] if item["name"] == "kimi")
    kimi_key = next(item for item in kimi["fields"] if item["name"] == "apiKey")
    assert openai_key["hint"] == "••••enai"
    assert openai_key["source"] == "managed"
    assert kimi_key["configured"] is False


def test_legacy_volcano_tts_access_token_migrates_to_scoped_api_key(tmp_path: Path) -> None:
    (tmp_path / "voice-provider-secrets.json").write_text(
        json.dumps({"tts": {"volcano": {"accessToken": "legacy-tts-app-key"}}}),
        encoding="utf-8",
    )

    registry = VoiceProviderRegistry(Settings(data_dir=tmp_path))

    provider = registry.tts["volcano"]
    assert provider.settings.voice_volcano_api_key is not None
    assert provider.settings.voice_volcano_api_key.get_secret_value() == "legacy-tts-app-key"
    status = registry.status()["providers"]["tts"][0]
    api_key = next(field for field in status["fields"] if field["name"] == "apiKey")
    assert api_key["hint"] == "••••-key"
    assert "legacy-tts-app-key" not in json.dumps(status, ensure_ascii=False)


@pytest.mark.asyncio
async def test_provider_configuration_is_scoped_and_persists_models(tmp_path: Path) -> None:
    registry = VoiceProviderRegistry(_configured_settings(tmp_path))

    await registry.update_configuration(
        "asr",
        "volcano",
        {"authMode": "app_id_token"},
        set(),
    )
    await registry.update_configuration(
        "asr",
        "openai",
        {"apiKey": "asr-only", "model": "whisper-custom", "language": "yue"},
        set(),
    )
    await registry.update_configuration(
        "tts",
        "openai",
        {"apiKey": "tts-only", "model": "tts-custom", "voice": "family-voice"},
        set(),
    )
    await registry.update_configuration("tts", "volcano", {"sampleRate": "48000"}, set())

    restored = VoiceProviderRegistry(_configured_settings(tmp_path))
    asr_settings = restored.asr["openai"].settings
    tts_settings = restored.tts["openai"].settings
    assert asr_settings.voice_openai_api_key.get_secret_value() == "asr-only"
    assert tts_settings.voice_openai_api_key.get_secret_value() == "tts-only"
    assert asr_settings.voice_openai_asr_model == "whisper-custom"
    assert asr_settings.voice_openai_asr_language == "yue"
    assert tts_settings.voice_openai_tts_model == "tts-custom"
    assert tts_settings.voice_openai_tts_voice == "family-voice"
    assert restored.tts["volcano"].settings.voice_volcano_sample_rate == 48_000
    assert restored.asr["volcano"].settings.voice_volcano_asr_auth_mode == "app_id_token"
    assert restored.configurations.config_path.stat().st_mode & 0o777 == 0o600
    encoded = json.dumps(restored.status(), ensure_ascii=False)
    assert "asr-only" not in encoded
    assert "tts-only" not in encoded
