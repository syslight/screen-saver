from __future__ import annotations

import os
from pathlib import Path
from typing import Literal

from pydantic import AliasChoices, Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="HOME_AGENT_",
        env_file=".env",
        extra="ignore",
        populate_by_name=True,
    )

    data_dir: Path = Field(
        default_factory=lambda: Path.home() / ".local" / "share" / "family-home-agent"
    )
    database_url_override: SecretStr | None = Field(default=None, repr=False)
    host: str = "127.0.0.1"
    port: int = Field(default=8790, ge=1, le=65535)
    log_level: str = "INFO"
    deployment_mode: Literal["edge", "cloud"] = "edge"
    session_ttl_seconds: int = Field(default=86_400, ge=60)
    pairing_ttl_seconds: int = Field(default=600, ge=30, le=3600)
    parent_enrollment_ttl_seconds: int = Field(default=600, ge=60, le=3600)
    hello_timeout_seconds: float = Field(default=5.0, gt=0)
    command_timeout_seconds: float = Field(default=10.0, gt=0)
    heartbeat_timeout_seconds: float = Field(default=45.0, gt=1)
    homework_max_file_bytes: int = Field(default=12 * 1024 * 1024, ge=1024)
    homework_max_files_per_submission: int = Field(default=6, ge=1, le=20)
    homework_quota_bytes: int = Field(default=5 * 1024 * 1024 * 1024, ge=1024)
    homework_model_enabled: bool = False
    homework_model_base_url: str = "https://api.moonshot.ai/v1"
    homework_model_api_key: SecretStr | None = Field(default=None, repr=False)
    homework_model_name: str = "kimi-k3"
    homework_model_timeout_seconds: float = Field(default=90.0, gt=0, le=600)
    media_photo_database: Path = Field(
        default_factory=lambda: (
            Path.home() / ".local" / "share" / "com.example.smart_frame" / "photo_index.db"
        )
    )
    media_frame_config: Path = Field(
        default_factory=lambda: (
            Path.home() / ".local" / "share" / "com.example.smart_frame" / "config.json"
        )
    )
    media_music_dir: Path = Field(
        default_factory=lambda: Path.home() / ".local" / "share" / "family-home-agent" / "music"
    )
    voice_agent_provider: Literal["glm", "kimi"] = "glm"
    voice_glm_base_url: str = "https://open.bigmodel.cn/api/coding/paas/v4"
    voice_glm_api_key: SecretStr | None = Field(
        default=None,
        validation_alias=AliasChoices(
            "HOME_AGENT_VOICE_GLM_API_KEY", "ZAI_API_KEY", "ZHIPUAI_API_KEY"
        ),
        repr=False,
    )
    voice_glm_model: str = "glm-5.2"
    voice_glm_temperature: float = Field(default=0.3, ge=0, le=2)
    voice_kimi_base_url: str = "https://api.moonshot.ai/v1"
    voice_kimi_api_key: SecretStr | None = Field(
        default=None,
        validation_alias=AliasChoices("HOME_AGENT_VOICE_KIMI_API_KEY", "MOONSHOT_API_KEY"),
        repr=False,
    )
    voice_kimi_model: str = "kimi-k2.7-code-highspeed"
    voice_kimi_temperature: float = Field(default=0.3, ge=0, le=2)
    voice_asr_provider: Literal["volcano", "local", "openai"] = "volcano"
    voice_asr_model: str = "small"
    voice_asr_language: str = "zh"
    voice_asr_device: Literal["cpu", "cuda"] = "cpu"
    voice_asr_compute_type: str = "int8"
    voice_asr_cpu_threads: int = Field(default=8, ge=1, le=32)
    voice_tts_model_dir: Path = Field(
        default_factory=lambda: (
            Path.home()
            / ".local"
            / "share"
            / "family-home-agent"
            / "models"
            / "zh_CN-huayan-medium"
        )
    )
    voice_tts_model_name: str = "zh_CN-huayan-medium"
    voice_tts_speaker_id: int = Field(default=0, ge=0)
    voice_tts_speed: float = Field(default=1.0, ge=0.25, le=4)
    voice_tts_volume: float = Field(default=1.0, ge=0.1, le=2)
    voice_tts_provider: Literal["auto", "volcano", "piper", "openai"] = "volcano"
    voice_openai_base_url: str = "https://api.openai.com/v1"
    voice_openai_api_key: SecretStr | None = Field(default=None, repr=False)
    voice_openai_asr_model: str = "gpt-4o-mini-transcribe"
    voice_openai_asr_language: str = "zh"
    voice_openai_tts_model: str = "gpt-4o-mini-tts"
    voice_openai_tts_voice: str = "coral"
    voice_openai_tts_speed: float = Field(default=1.0, ge=0.25, le=4)
    voice_volcano_asr_auth_mode: Literal["app_key", "app_id_token"] = "app_key"
    voice_volcano_asr_ws_url: str = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    voice_volcano_asr_resource_id: str = "volc.bigasr.sauc.duration"
    voice_volcano_asr_model: str = "bigmodel"
    voice_volcano_asr_language: str = "zh-CN"
    voice_volcano_asr_chunk_bytes: int = Field(default=6400, ge=640, le=64_000)
    voice_volcano_tts_url: str = "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
    voice_volcano_app_id: str = ""
    voice_volcano_api_key: SecretStr | None = Field(default=None, repr=False)
    voice_volcano_access_token: SecretStr | None = Field(default=None, repr=False)
    voice_volcano_resource_id: str = "volc.service_type.10029"
    voice_volcano_voice: str = "zh_female_wanwanxiaohe_moon_bigtts"
    voice_volcano_sample_rate: int = Field(default=24_000, ge=8000, le=48_000)
    voice_volcano_speech_rate: int = Field(default=0, ge=-50, le=100)
    voice_volcano_pitch_rate: int = Field(default=0, ge=-12, le=12)
    voice_volcano_loudness_rate: int = Field(default=0, ge=-50, le=100)
    voice_volcano_tts_use_cache: bool = True
    voice_tts_stream_chunk_bytes: int = Field(default=2400, ge=640, le=32_000)
    voice_timeout_seconds: float = Field(default=60.0, gt=0, le=300)
    voice_max_audio_bytes: int = Field(default=2 * 1024 * 1024, ge=32_000)

    @property
    def database_url(self) -> str:
        if self.database_url_override is not None:
            return self.database_url_override.get_secret_value()
        return f"sqlite+aiosqlite:///{self.data_dir / 'home_agent.db'}"

    def ensure_directories(self) -> None:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.data_dir, 0o700)
