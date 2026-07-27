from __future__ import annotations

import asyncio
import importlib.util
import json
import logging
import os
import time
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal, cast

import httpx
from pydantic import SecretStr

from home_agent.config import Settings
from home_agent.services.coding_agent import CodingAgentProvider
from home_agent.services.local_speech import (
    LocalFasterWhisperAsr,
    LocalPiperTts,
    OpenAiSpeechRecognizer,
    OpenAiSpeechSynthesizer,
    SpeechRecognizer,
    SpeechSynthesizer,
    StreamingSpeechRecognitionSession,
    VolcanoStreamingAsr,
    VolcanoUnidirectionalTts,
)

logger = logging.getLogger(__name__)

ProviderKind = Literal["asr", "tts", "llm"]
ProviderFieldValue = str | int | float | bool
ProviderFieldType = Literal["text", "secret", "number", "boolean", "select", "path"]


class ProviderSelectionError(ValueError):
    pass


class ProviderNotConfiguredError(ValueError):
    pass


class ProviderConfigurationError(ValueError):
    pass


@dataclass(frozen=True)
class VoiceProviderSelection:
    asr: str
    tts: str
    llm: str


@dataclass(frozen=True)
class ProviderCheck:
    state: Literal["healthy", "error"]
    checked_at: str
    latency_ms: int
    message: str


@dataclass(frozen=True)
class ProviderTestResult:
    text: str | None
    audio: bytes | None
    latency_ms: int


@dataclass(frozen=True)
class ProviderField:
    name: str
    attribute: str
    label: str
    field_type: ProviderFieldType
    section: Literal["credential", "model", "voice", "parameter", "advanced"]
    required: bool = False
    options: tuple[tuple[ProviderFieldValue, str], ...] = ()
    allow_custom: bool = False
    minimum: float | None = None
    maximum: float | None = None
    help_text: str | None = None
    wrap_secret: bool = True

    @property
    def secret(self) -> bool:
        return self.field_type == "secret"


def _choice(value: ProviderFieldValue, label: str | None = None) -> tuple[ProviderFieldValue, str]:
    return value, label or str(value)


_PROVIDER_FIELDS: dict[tuple[ProviderKind, str], tuple[ProviderField, ...]] = {
    ("asr", "volcano"): (
        ProviderField(
            "authMode",
            "voice_volcano_asr_auth_mode",
            "鉴权方式",
            "select",
            "credential",
            required=True,
            options=(
                _choice("app_key", "新版控制台：APP Key"),
                _choice("app_id_token", "旧版控制台：App ID + Access Token"),
            ),
            help_text="新项目请选择 APP Key；只有旧版语音应用才使用 App ID + Access Token。",
        ),
        ProviderField(
            "apiKey",
            "voice_volcano_api_key",
            "APP Key",
            "secret",
            "credential",
            help_text="来自豆包语音新版控制台当前项目的 API Key 页面，不是火山 IAM Access Key。",
        ),
        ProviderField(
            "appId",
            "voice_volcano_app_id",
            "App ID",
            "secret",
            "credential",
            wrap_secret=False,
        ),
        ProviderField(
            "accessToken",
            "voice_volcano_access_token",
            "Access Token",
            "secret",
            "credential",
        ),
        ProviderField(
            "model",
            "voice_volcano_asr_model",
            "识别模型",
            "select",
            "model",
            required=True,
            options=(_choice("bigmodel", "豆包语音识别大模型"),),
            allow_custom=True,
        ),
        ProviderField(
            "language",
            "voice_volcano_asr_language",
            "识别语言",
            "select",
            "model",
            required=True,
            options=(_choice("zh-CN", "中文/中英混合"), _choice("en-US", "英文")),
            allow_custom=True,
        ),
        ProviderField(
            "resourceId",
            "voice_volcano_asr_resource_id",
            "资源 ID",
            "select",
            "advanced",
            required=True,
            options=(
                _choice("volc.bigasr.sauc.duration", "流式小时版"),
                _choice("volc.bigasr.sauc.concurrent", "流式并发版"),
                _choice("volc.seedasr.sauc.duration", "兼容旧资源 ID"),
            ),
            allow_custom=True,
        ),
        ProviderField(
            "chunkBytes",
            "voice_volcano_asr_chunk_bytes",
            "上传分块字节数",
            "number",
            "advanced",
            minimum=640,
            maximum=64_000,
        ),
        ProviderField(
            "websocketUrl",
            "voice_volcano_asr_ws_url",
            "WebSocket 地址",
            "text",
            "advanced",
            required=True,
        ),
    ),
    ("asr", "local"): (
        ProviderField(
            "model",
            "voice_asr_model",
            "Whisper 模型",
            "select",
            "model",
            required=True,
            options=tuple(
                _choice(value) for value in ("tiny", "base", "small", "medium", "large-v3", "turbo")
            ),
            allow_custom=True,
        ),
        ProviderField(
            "language",
            "voice_asr_language",
            "识别语言",
            "select",
            "model",
            required=True,
            options=(_choice("zh", "中文"), _choice("en", "英文"), _choice("auto", "自动检测")),
            allow_custom=True,
        ),
        ProviderField(
            "device",
            "voice_asr_device",
            "推理设备",
            "select",
            "parameter",
            options=(_choice("cpu", "CPU"), _choice("cuda", "CUDA")),
        ),
        ProviderField("computeType", "voice_asr_compute_type", "计算精度", "text", "parameter"),
        ProviderField(
            "cpuThreads",
            "voice_asr_cpu_threads",
            "CPU 线程数",
            "number",
            "parameter",
            minimum=1,
            maximum=32,
        ),
    ),
    ("asr", "openai"): (
        ProviderField("apiKey", "voice_openai_api_key", "API Key", "secret", "credential"),
        ProviderField(
            "model",
            "voice_openai_asr_model",
            "识别模型",
            "select",
            "model",
            required=True,
            options=tuple(
                _choice(value)
                for value in ("gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1")
            ),
            allow_custom=True,
        ),
        ProviderField(
            "language",
            "voice_openai_asr_language",
            "识别语言",
            "select",
            "model",
            options=(_choice("zh", "中文"), _choice("en", "英文")),
            allow_custom=True,
        ),
        ProviderField(
            "baseUrl", "voice_openai_base_url", "Base URL", "text", "advanced", required=True
        ),
    ),
    ("tts", "volcano"): (
        ProviderField(
            "apiKey",
            "voice_volcano_api_key",
            "APP Key",
            "secret",
            "credential",
            required=True,
            help_text="来自豆包语音控制台当前项目的 API Key 页面；不会返回或回显明文。",
        ),
        ProviderField(
            "model",
            "voice_volcano_resource_id",
            "模型/资源 ID",
            "select",
            "model",
            required=True,
            options=(
                _choice("volc.service_type.10029", "豆包语音合成大模型 1.0"),
                _choice("seed-tts-2.0", "豆包语音合成大模型 2.0"),
            ),
            allow_custom=True,
        ),
        ProviderField(
            "voice",
            "voice_volcano_voice",
            "音色/角色",
            "select",
            "voice",
            required=True,
            options=(
                _choice("zh_female_wanwanxiaohe_moon_bigtts", "湾湾小何 · 台湾女声"),
                _choice("zh_female_wenrouxiaoya_moon_bigtts", "温柔小雅 · 中文女声"),
                _choice("zh_female_tianmeixiaoyuan_moon_bigtts", "甜美小源 · 中文女声"),
                _choice("zh_male_jieshuoxiaoming_moon_bigtts", "解说小明 · 中文男声"),
                _choice("zh_female_heainainai_tob", "和蔼奶奶 · 中文女声"),
            ),
            allow_custom=True,
        ),
        ProviderField(
            "sampleRate",
            "voice_volcano_sample_rate",
            "采样率",
            "select",
            "parameter",
            options=tuple(
                _choice(value, f"{value} Hz") for value in (8000, 16_000, 24_000, 48_000)
            ),
        ),
        ProviderField(
            "speechRate",
            "voice_volcano_speech_rate",
            "语速",
            "number",
            "parameter",
            minimum=-50,
            maximum=100,
        ),
        ProviderField(
            "pitchRate",
            "voice_volcano_pitch_rate",
            "音调",
            "number",
            "parameter",
            minimum=-12,
            maximum=12,
        ),
        ProviderField(
            "loudnessRate",
            "voice_volcano_loudness_rate",
            "音量增益",
            "number",
            "parameter",
            minimum=-50,
            maximum=100,
        ),
        ProviderField(
            "useCache",
            "voice_volcano_tts_use_cache",
            "启用供应商缓存",
            "boolean",
            "advanced",
            help_text="相同文本和参数可复用供应商缓存，降低延迟。",
        ),
        ProviderField(
            "apiUrl",
            "voice_volcano_tts_url",
            "HTTP 流式接口",
            "text",
            "advanced",
            required=True,
        ),
    ),
    ("tts", "piper"): (
        ProviderField(
            "model", "voice_tts_model_name", "语音模型/角色", "text", "model", required=True
        ),
        ProviderField(
            "modelDir", "voice_tts_model_dir", "模型目录", "path", "advanced", required=True
        ),
        ProviderField(
            "speakerId", "voice_tts_speaker_id", "Speaker ID", "number", "voice", minimum=0
        ),
        ProviderField(
            "speed", "voice_tts_speed", "语速倍率", "number", "parameter", minimum=0.25, maximum=4
        ),
        ProviderField(
            "volume", "voice_tts_volume", "音量倍率", "number", "parameter", minimum=0.1, maximum=2
        ),
    ),
    ("tts", "openai"): (
        ProviderField(
            "apiKey", "voice_openai_api_key", "API Key", "secret", "credential", required=True
        ),
        ProviderField(
            "model",
            "voice_openai_tts_model",
            "合成模型",
            "select",
            "model",
            required=True,
            options=tuple(_choice(value) for value in ("gpt-4o-mini-tts", "tts-1", "tts-1-hd")),
            allow_custom=True,
        ),
        ProviderField(
            "voice",
            "voice_openai_tts_voice",
            "音色/角色",
            "select",
            "voice",
            required=True,
            options=tuple(
                _choice(value)
                for value in (
                    "coral",
                    "alloy",
                    "ash",
                    "ballad",
                    "echo",
                    "fable",
                    "nova",
                    "onyx",
                    "sage",
                    "shimmer",
                )
            ),
            allow_custom=True,
        ),
        ProviderField(
            "speed",
            "voice_openai_tts_speed",
            "语速倍率",
            "number",
            "parameter",
            minimum=0.25,
            maximum=4,
        ),
        ProviderField(
            "baseUrl", "voice_openai_base_url", "Base URL", "text", "advanced", required=True
        ),
    ),
    ("llm", "glm"): (
        ProviderField(
            "apiKey", "voice_glm_api_key", "API Key", "secret", "credential", required=True
        ),
        ProviderField(
            "model",
            "voice_glm_model",
            "模型",
            "select",
            "model",
            required=True,
            options=tuple(
                _choice(value) for value in ("glm-5.2", "glm-5-turbo", "glm-4.7", "glm-4.6v")
            ),
            allow_custom=True,
        ),
        ProviderField(
            "temperature",
            "voice_glm_temperature",
            "Temperature",
            "number",
            "parameter",
            minimum=0,
            maximum=2,
        ),
        ProviderField(
            "baseUrl", "voice_glm_base_url", "Base URL", "text", "advanced", required=True
        ),
    ),
    ("llm", "kimi"): (
        ProviderField(
            "apiKey", "voice_kimi_api_key", "API Key", "secret", "credential", required=True
        ),
        ProviderField(
            "model",
            "voice_kimi_model",
            "模型",
            "select",
            "model",
            required=True,
            options=tuple(
                _choice(value) for value in ("kimi-k3", "kimi-k2.7-code-highspeed", "kimi-k2.5")
            ),
            allow_custom=True,
        ),
        ProviderField(
            "temperature",
            "voice_kimi_temperature",
            "Temperature",
            "number",
            "parameter",
            minimum=0,
            maximum=2,
        ),
        ProviderField(
            "baseUrl", "voice_kimi_base_url", "Base URL", "text", "advanced", required=True
        ),
    ),
}


class ProviderConfigurationStore:
    """Persists provider-scoped parameters and write-only credentials."""

    _legacy_credentials: dict[str, tuple[tuple[ProviderKind, str, str], ...]] = {
        "volcanoAppId": (("asr", "volcano", "appId"),),
        "volcanoApiKey": (("asr", "volcano", "apiKey"), ("tts", "volcano", "apiKey")),
        "volcanoAccessToken": (
            ("asr", "volcano", "accessToken"),
            ("tts", "volcano", "apiKey"),
        ),
        "openaiApiKey": (("asr", "openai", "apiKey"), ("tts", "openai", "apiKey")),
        "glmApiKey": (("llm", "glm", "apiKey"),),
        "kimiApiKey": (("llm", "kimi", "apiKey"),),
    }

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.config_path = settings.data_dir / "voice-provider-config.json"
        self.secrets_path = settings.data_dir / "voice-provider-secrets.json"
        self.path = self.secrets_path  # Compatibility for existing operations/tests.
        self._config: dict[tuple[ProviderKind, str], dict[str, ProviderFieldValue]] = {}
        self._secrets: dict[tuple[ProviderKind, str], dict[str, ProviderFieldValue]] = {}
        self._load()

    def settings_for(self, kind: ProviderKind, name: str) -> Settings:
        configured = self.settings.model_copy(deep=True)
        key = (kind, name)
        managed_config = self._config.get(key, {})
        managed_secrets = self._secrets.get(key, {})
        for field in _PROVIDER_FIELDS[key]:
            if field.secret and field.name in managed_secrets:
                raw: ProviderFieldValue = managed_secrets[field.name]
            elif not field.secret and field.name in managed_config:
                raw = managed_config[field.name]
            else:
                continue
            value: object = raw
            current = getattr(configured, field.attribute)
            if field.secret:
                if field.wrap_secret:
                    value = SecretStr(str(raw)) if raw else None
                else:
                    value = str(raw)
            elif isinstance(current, Path):
                value = Path(str(raw))
            setattr(configured, field.attribute, value)
        return configured

    def fields_status(
        self, kind: ProviderKind, name: str, configured: Settings
    ) -> list[dict[str, object]]:
        key = (kind, name)
        result: list[dict[str, object]] = []
        for field in _PROVIDER_FIELDS[key]:
            value = getattr(configured, field.attribute)
            item: dict[str, object] = {
                "name": field.name,
                "label": field.label,
                "type": field.field_type,
                "section": field.section,
                "required": field.required,
                "allowCustom": field.allow_custom,
            }
            if field.options:
                item["options"] = [
                    {"value": option, "label": label} for option, label in field.options
                ]
            if field.minimum is not None:
                item["min"] = field.minimum
            if field.maximum is not None:
                item["max"] = field.maximum
            if field.help_text:
                item["help"] = field.help_text
            if field.secret:
                plaintext = (
                    value.get_secret_value() if isinstance(value, SecretStr) else str(value or "")
                )
                item["configured"] = bool(plaintext)
                item["source"] = self._field_source(key, field, bool(plaintext))
                if plaintext:
                    item["hint"] = self._hint(plaintext)
            else:
                item["value"] = str(value) if isinstance(value, Path) else value
                item["source"] = (
                    "managed" if field.name in self._config.get(key, {}) else "environment"
                )
            result.append(item)
        return result

    def update(
        self,
        kind: ProviderKind,
        name: str,
        values: dict[str, ProviderFieldValue],
        clear: set[str],
    ) -> None:
        key = (kind, name)
        fields = {field.name: field for field in _PROVIDER_FIELDS[key]}
        unknown = (set(values) | clear).difference(fields)
        if unknown:
            raise ProviderConfigurationError(f"unknown fields: {', '.join(sorted(unknown))}")
        overlap = set(values).intersection(clear)
        if overlap:
            raise ProviderConfigurationError(
                f"fields cannot be updated and cleared together: {', '.join(sorted(overlap))}"
            )
        config = {provider: dict(items) for provider, items in self._config.items()}
        secrets = {provider: dict(items) for provider, items in self._secrets.items()}
        provider_config = config.setdefault(key, {})
        provider_secrets = secrets.setdefault(key, {})
        for field_name, raw in values.items():
            field = fields[field_name]
            value = self._validate_value(field, raw)
            if field.secret:
                provider_secrets[field_name] = cast(str, value)
            else:
                provider_config[field_name] = value
        for field_name in clear:
            field = fields[field_name]
            if field.secret:
                # An explicit empty value must override an environment secret.
                provider_secrets[field_name] = ""
            else:
                provider_config.pop(field_name, None)
        self._persist(self.config_path, config)
        self._persist(self.secrets_path, secrets)
        self._config = config
        self._secrets = secrets

    def update_legacy_credentials(self, values: dict[str, str], clear: set[str]) -> None:
        unknown = (set(values) | clear).difference(self._legacy_credentials)
        if unknown:
            raise ProviderConfigurationError(f"unknown credentials: {', '.join(sorted(unknown))}")
        for legacy_name, raw in values.items():
            for kind, provider, field in self._legacy_credentials[legacy_name]:
                self.update(kind, provider, {field: raw}, set())
        for legacy_name in clear:
            for kind, provider, field in self._legacy_credentials[legacy_name]:
                self.update(kind, provider, {}, {field})

    def _field_source(
        self, key: tuple[ProviderKind, str], field: ProviderField, configured: bool
    ) -> str | None:
        if field.name in self._secrets.get(key, {}):
            return "managed"
        return "environment" if configured else None

    def _load(self) -> None:
        self._config = self._load_nested(self.config_path, secrets=False)
        self._secrets = self._load_nested(self.secrets_path, secrets=True)
        for path in (self.config_path, self.secrets_path):
            if path.is_file():
                try:
                    os.chmod(path, 0o600)
                except OSError:
                    logger.warning("unable to tighten provider configuration file permissions")

    def _load_nested(
        self, path: Path, *, secrets: bool
    ) -> dict[tuple[ProviderKind, str], dict[str, ProviderFieldValue]]:
        if not path.is_file():
            return {}
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(payload, dict):
                raise TypeError
            if secrets and payload and all(isinstance(value, str) for value in payload.values()):
                return self._migrate_legacy(cast(dict[str, str], payload))
            result: dict[tuple[ProviderKind, str], dict[str, ProviderFieldValue]] = {}
            for raw_kind, providers in payload.items():
                if raw_kind not in {"asr", "tts", "llm"} or not isinstance(providers, dict):
                    continue
                kind = cast(ProviderKind, raw_kind)
                for name, values in providers.items():
                    key = (kind, str(name))
                    if key not in _PROVIDER_FIELDS or not isinstance(values, dict):
                        continue
                    if (
                        secrets
                        and key == ("tts", "volcano")
                        and "apiKey" not in values
                        and isinstance(values.get("accessToken"), str)
                    ):
                        values = {**values, "apiKey": values["accessToken"]}
                    allowed = {field.name: field for field in _PROVIDER_FIELDS[key]}
                    cleaned: dict[str, ProviderFieldValue] = {}
                    for field_name, value in values.items():
                        field = allowed.get(field_name)
                        if field is None or field.secret != secrets:
                            continue
                        try:
                            cleaned[field_name] = self._validate_value(field, value)
                        except ProviderConfigurationError:
                            logger.warning("ignoring invalid %s.%s.%s", kind, name, field_name)
                    if cleaned:
                        result[key] = cleaned
            return result
        except (OSError, TypeError, ValueError, json.JSONDecodeError):
            logger.warning("provider configuration file is invalid; ignoring %s", path.name)
            return {}

    def _migrate_legacy(
        self, payload: dict[str, str]
    ) -> dict[tuple[ProviderKind, str], dict[str, ProviderFieldValue]]:
        result: dict[tuple[ProviderKind, str], dict[str, ProviderFieldValue]] = {}
        for legacy_name, value in payload.items():
            for kind, provider, field in self._legacy_credentials.get(legacy_name, ()):
                result.setdefault((kind, provider), {})[field] = value
        return result

    @staticmethod
    def _validate_value(field: ProviderField, raw: object) -> ProviderFieldValue:
        if field.secret or field.field_type in {"text", "path", "select"}:
            if (
                field.field_type == "select"
                and isinstance(raw, (int, float))
                and not isinstance(raw, bool)
            ):
                value: ProviderFieldValue = raw
            elif not isinstance(raw, str):
                raise ProviderConfigurationError(f"{field.name} must be text")
            else:
                value = raw.strip()
            if field.field_type == "select" and isinstance(value, str):
                for option, _label in field.options:
                    if str(option) == value:
                        value = option
                        break
            if field.required and value == "" and not field.secret:
                raise ProviderConfigurationError(f"{field.name} cannot be empty")
            if field.secret and len(str(value)) > 8192:
                raise ProviderConfigurationError(f"{field.name} is too long")
        elif field.field_type == "boolean":
            if not isinstance(raw, bool):
                raise ProviderConfigurationError(f"{field.name} must be boolean")
            value = raw
        else:
            if isinstance(raw, bool) or not isinstance(raw, (int, float)):
                raise ProviderConfigurationError(f"{field.name} must be numeric")
            value = raw
            if isinstance(field.minimum, int) and isinstance(field.maximum, int):
                if isinstance(raw, float) and not raw.is_integer():
                    value = raw
                else:
                    value = int(raw)
        if field.minimum is not None and isinstance(value, (int, float)) and value < field.minimum:
            raise ProviderConfigurationError(f"{field.name} is below the minimum")
        if field.maximum is not None and isinstance(value, (int, float)) and value > field.maximum:
            raise ProviderConfigurationError(f"{field.name} is above the maximum")
        if field.options and not field.allow_custom:
            allowed_values = {option for option, _label in field.options}
            if value not in allowed_values:
                raise ProviderConfigurationError(f"{field.name} is not an allowed value")
        return value

    @staticmethod
    def _persist(
        path: Path,
        values: dict[tuple[ProviderKind, str], dict[str, ProviderFieldValue]],
    ) -> None:
        payload: dict[str, dict[str, dict[str, ProviderFieldValue]]] = {}
        for (kind, name), fields in values.items():
            if fields:
                payload.setdefault(kind, {})[name] = fields
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.chmod(temporary, 0o600)
        temporary.replace(path)

    @staticmethod
    def _hint(value: str) -> str:
        visible = value[-4:] if len(value) > 4 else value[-1:]
        return f"••••{visible}"


def _provider_error_message(kind: ProviderKind, name: str, error: BaseException) -> str:
    response = getattr(error, "response", None)
    status = getattr(response, "status_code", None)
    body = getattr(response, "body", b"")
    if not body and response is not None:
        body = getattr(response, "content", b"")
    if isinstance(body, str):
        normalized = body.lower()
    elif isinstance(body, (bytes, bytearray)):
        normalized = bytes(body).decode("utf-8", errors="ignore").lower()
    else:
        normalized = ""

    if kind == "asr" and name == "volcano":
        if "invalid x-api-key" in normalized:
            return "鉴权失败：APP Key 无效；请复制当前豆包语音项目 API Key 页面中的 APP Key"
        if "requested grant not found" in normalized:
            return "鉴权失败：旧版应用未开通所选 ASR 资源，或 App ID 与 Access Token 不匹配"
    if status == 401:
        return "鉴权失败（HTTP 401）：请检查该 Provider 的凭据和鉴权方式"
    if status == 403:
        return "没有调用权限（HTTP 403）：请检查服务开通状态、项目授权和资源 ID"
    if status == 429:
        return "调用受限（HTTP 429）：请检查额度、并发限制或稍后重试"
    if isinstance(error, (TimeoutError, httpx.TimeoutException)):
        return "调用超时：请检查网络、供应商地址或增大超时时间"
    if isinstance(error, httpx.ConnectError):
        return "连接失败：请检查网络、代理和 Provider Base URL"
    return f"调用失败（{type(error).__name__}）"


class VoiceProviderRegistry:
    """Owns provider instances, scoped configuration, runtime selection and health."""

    _labels: dict[ProviderKind, dict[str, str]] = {
        "asr": {"volcano": "火山流式 ASR", "local": "本地 faster-whisper", "openai": "OpenAI ASR"},
        "tts": {"volcano": "火山单向流式 TTS", "piper": "本地 Piper", "openai": "OpenAI TTS"},
        "llm": {"glm": "GLM", "kimi": "Kimi"},
    }
    _streaming = {("asr", "volcano"), ("tts", "volcano")}

    def __init__(
        self,
        settings: Settings,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.settings = settings
        self.transport = transport
        self.selection_path = settings.data_dir / "voice-providers.json"
        self.configurations = ProviderConfigurationStore(settings)
        self.credentials = self.configurations  # Backward-compatible attribute.
        self._provider_settings: dict[tuple[ProviderKind, str], Settings] = {}
        self.asr: dict[str, SpeechRecognizer] = {}
        self.tts: dict[str, SpeechSynthesizer] = {}
        self.llm: dict[str, CodingAgentProvider] = {}
        self._rebuild_all()
        default_tts = settings.voice_tts_provider
        if default_tts == "auto":
            default_tts = "volcano" if self._configured("tts", "volcano") else "piper"
        self._selection = self._load_selection(
            VoiceProviderSelection(
                asr=settings.voice_asr_provider,
                tts=default_tts,
                llm=settings.voice_agent_provider,
            )
        )
        self._checks: dict[tuple[ProviderKind, str], ProviderCheck] = {}
        self._selection_lock = asyncio.Lock()
        self._configuration_lock = asyncio.Lock()

    @property
    def selection(self) -> VoiceProviderSelection:
        return self._selection

    @property
    def selected_asr(self) -> SpeechRecognizer:
        return self.asr[self._selection.asr]

    @property
    def selected_tts(self) -> SpeechSynthesizer:
        return self.tts[self._selection.tts]

    @property
    def selected_llm(self) -> CodingAgentProvider:
        return self.llm[self._selection.llm]

    async def open_asr_stream(self) -> StreamingSpeechRecognitionSession | None:
        provider = self.selected_asr
        if not isinstance(provider, VolcanoStreamingAsr):
            return None
        started = time.perf_counter()
        try:
            session = await provider.open_stream()
        except Exception as error:
            self.record_error("asr", self._selection.asr, error, started)
            raise
        self.record_success("asr", self._selection.asr, started, "流式连接正常")
        return session

    async def select(self, selection: VoiceProviderSelection) -> None:
        self._validate_selection(selection)
        async with self._selection_lock:
            await asyncio.to_thread(self._persist_selection, selection)
            self._selection = selection

    def status(self) -> dict[str, object]:
        return {
            "selection": asdict(self._selection),
            "providers": {
                kind: [self._provider_status(kind, name) for name in names]
                for kind, names in self._labels.items()
            },
        }

    async def update_configuration(
        self,
        kind: ProviderKind,
        name: str,
        values: dict[str, ProviderFieldValue],
        clear: set[str],
    ) -> None:
        self._validate_provider(kind, name)
        async with self._configuration_lock:
            await asyncio.to_thread(self.configurations.update, kind, name, values, clear)
            self._rebuild_provider(kind, name)
            self._checks.pop((kind, name), None)

    async def update_credentials(self, values: dict[str, str], clear: set[str]) -> None:
        """Compatibility bridge for the old flat write-only credential endpoint."""
        async with self._configuration_lock:
            await asyncio.to_thread(self.configurations.update_legacy_credentials, values, clear)
            self._rebuild_all()
            self._checks.clear()

    async def check(self, kind: ProviderKind, name: str) -> dict[str, object]:
        self._validate_provider(kind, name)
        if not self._configured(kind, name):
            raise ProviderNotConfiguredError(f"{kind} provider {name} is not configured")
        started = time.perf_counter()
        success_message = "调用正常"
        try:
            if kind == "asr":
                if name == "local":
                    if importlib.util.find_spec("faster_whisper") is None:
                        raise RuntimeError("faster-whisper is not installed")
                    success_message = "本地依赖可用"
                else:
                    await self.asr[name].transcribe(b"\0\0" * 1600)
            elif kind == "tts":
                if name == "piper":
                    if importlib.util.find_spec("piper") is None:
                        raise RuntimeError("piper is not installed")
                    success_message = "本地依赖与模型文件可用"
                else:
                    await self.tts[name].synthesize("语音服务状态检查。")
            else:
                await self.llm[name].health_check()
        except Exception as error:
            self.record_error(kind, name, error, started)
            raise
        self.record_success(kind, name, started, success_message)
        return self._provider_status(kind, name)

    async def test(
        self,
        kind: ProviderKind,
        name: str,
        *,
        text: str | None = None,
        pcm: bytes | None = None,
    ) -> ProviderTestResult:
        self._validate_provider(kind, name)
        if not self._configured(kind, name):
            raise ProviderNotConfiguredError(f"{kind} provider {name} is not configured")
        started = time.perf_counter()
        try:
            output_text: str | None = None
            audio: bytes | None = None
            if kind == "asr":
                if not pcm:
                    raise ProviderConfigurationError("ASR test audio is required")
                output_text = await self.asr[name].transcribe(pcm)
            elif kind == "tts":
                if not text or not text.strip():
                    raise ProviderConfigurationError("TTS test text is required")
                audio = await self.tts[name].synthesize(text.strip())
            else:
                if not text or not text.strip():
                    raise ProviderConfigurationError("LLM test prompt is required")
                test_node = f"provider-test-{name}"
                try:
                    output_text = await self.llm[name].reply(text.strip(), node_id=test_node)
                finally:
                    self.llm[name].clear(test_node)
        except Exception as error:
            self.record_error(kind, name, error, started)
            raise
        latency_ms = round((time.perf_counter() - started) * 1000)
        self.record_success(kind, name, started, "交互测试正常")
        return ProviderTestResult(text=output_text, audio=audio, latency_ms=latency_ms)

    def record_success(
        self,
        kind: ProviderKind,
        name: str,
        started: float,
        message: str = "最近调用正常",
    ) -> None:
        self._checks[(kind, name)] = ProviderCheck(
            state="healthy",
            checked_at=datetime.now(UTC).isoformat(),
            latency_ms=round((time.perf_counter() - started) * 1000),
            message=message,
        )

    def record_error(
        self, kind: ProviderKind, name: str, error: BaseException, started: float
    ) -> None:
        logger.warning("%s provider %s failed: %s", kind, name, type(error).__name__)
        self._checks[(kind, name)] = ProviderCheck(
            state="error",
            checked_at=datetime.now(UTC).isoformat(),
            latency_ms=round((time.perf_counter() - started) * 1000),
            message=_provider_error_message(kind, name, error),
        )

    def clear(self, node_id: str) -> None:
        for provider in self.llm.values():
            provider.clear(node_id)

    def _rebuild_all(self) -> None:
        for kind, providers in self._labels.items():
            for name in providers:
                self._rebuild_provider(kind, name)

    def _rebuild_provider(self, kind: ProviderKind, name: str) -> None:
        configured = self.configurations.settings_for(kind, name)
        self._provider_settings[(kind, name)] = configured
        if kind == "asr":
            if name == "volcano":
                self.asr[name] = VolcanoStreamingAsr(configured)
            elif name == "local":
                self.asr[name] = LocalFasterWhisperAsr(configured)
            else:
                self.asr[name] = OpenAiSpeechRecognizer(configured, transport=self.transport)
        elif kind == "tts":
            if name == "volcano":
                self.tts[name] = VolcanoUnidirectionalTts(configured, transport=self.transport)
            elif name == "piper":
                self.tts[name] = LocalPiperTts(configured)
            else:
                self.tts[name] = OpenAiSpeechSynthesizer(configured, transport=self.transport)
        else:
            self.llm[name] = CodingAgentProvider(
                configured,
                provider_name=cast(Literal["glm", "kimi"], name),
                transport=self.transport,
            )

    def _configured(self, kind: ProviderKind, name: str) -> bool:
        if kind == "asr":
            if name == "local":
                return True
            return bool(getattr(self.asr[name], "configured", False))
        if kind == "tts":
            if name == "piper":
                settings = self._provider_settings[(kind, name)]
                model_dir = settings.voice_tts_model_dir
                model = settings.voice_tts_model_name
                return (model_dir / f"{model}.onnx").is_file() and (
                    model_dir / f"{model}.onnx.json"
                ).is_file()
            return bool(getattr(self.tts[name], "configured", False))
        return self.llm[name].configured

    def _provider_status(self, kind: ProviderKind, name: str) -> dict[str, object]:
        configured = self._configured(kind, name)
        last = self._checks.get((kind, name))
        active = getattr(self._selection, kind) == name
        state = last.state if last is not None else ("ready" if configured else "unconfigured")
        settings = self._provider_settings[(kind, name)]
        result: dict[str, object] = {
            "name": name,
            "label": self._labels[kind][name],
            "configured": configured,
            "active": active,
            "streaming": (kind, name) in self._streaming,
            "state": state,
            "model": self._model_name(kind, name),
            "fields": self.configurations.fields_status(kind, name, settings),
        }
        voice = self._voice_name(kind, name)
        if voice is not None:
            result["voice"] = voice
        language = self._language_name(kind, name)
        if language is not None:
            result["language"] = language
        if last is not None:
            result.update(
                {
                    "lastCheckedAt": last.checked_at,
                    "latencyMs": last.latency_ms,
                    "message": last.message,
                }
            )
        return result

    def _model_name(self, kind: ProviderKind, name: str) -> str:
        settings = self._provider_settings[(kind, name)]
        if kind == "asr":
            return {
                "volcano": settings.voice_volcano_asr_model,
                "local": settings.voice_asr_model,
                "openai": settings.voice_openai_asr_model,
            }[name]
        if kind == "tts":
            return {
                "volcano": settings.voice_volcano_resource_id,
                "piper": settings.voice_tts_model_name,
                "openai": settings.voice_openai_tts_model,
            }[name]
        return self.llm[name].config.model

    def _voice_name(self, kind: ProviderKind, name: str) -> str | None:
        if kind != "tts":
            return None
        settings = self._provider_settings[(kind, name)]
        return {
            "volcano": settings.voice_volcano_voice,
            "piper": str(settings.voice_tts_speaker_id),
            "openai": settings.voice_openai_tts_voice,
        }[name]

    def _language_name(self, kind: ProviderKind, name: str) -> str | None:
        if kind != "asr":
            return None
        settings = self._provider_settings[(kind, name)]
        return {
            "volcano": settings.voice_volcano_asr_language,
            "local": settings.voice_asr_language,
            "openai": settings.voice_openai_asr_language,
        }[name]

    def _load_selection(self, fallback: VoiceProviderSelection) -> VoiceProviderSelection:
        if not self.selection_path.is_file():
            return fallback
        try:
            payload = json.loads(self.selection_path.read_text(encoding="utf-8"))
            selection = VoiceProviderSelection(
                asr=str(payload["asr"]),
                tts=str(payload["tts"]),
                llm=str(payload["llm"]),
            )
            self._validate_selection(selection)
            return selection
        except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError):
            logger.warning("voice provider selection is invalid; using environment defaults")
            return fallback

    def _persist_selection(self, selection: VoiceProviderSelection) -> None:
        self.selection_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.selection_path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(asdict(selection), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.chmod(temporary, 0o600)
        temporary.replace(self.selection_path)

    def _validate_selection(self, selection: VoiceProviderSelection) -> None:
        self._validate_provider("asr", selection.asr)
        self._validate_provider("tts", selection.tts)
        self._validate_provider("llm", selection.llm)

    def _validate_provider(self, kind: ProviderKind, name: str) -> None:
        if name not in self._labels[kind]:
            raise ProviderSelectionError(f"unknown {kind} provider: {name}")


def provider_kind(value: str) -> ProviderKind:
    if value not in {"asr", "tts", "llm"}:
        raise ProviderSelectionError(f"unknown provider kind: {value}")
    return cast(ProviderKind, value)
