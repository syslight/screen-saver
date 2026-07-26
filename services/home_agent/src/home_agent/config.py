from __future__ import annotations

from pathlib import Path

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="HOME_AGENT_", env_file=".env", extra="ignore")

    data_dir: Path = Field(
        default_factory=lambda: Path.home() / ".local" / "share" / "family-home-agent"
    )
    database_url_override: SecretStr | None = Field(default=None, repr=False)
    host: str = "127.0.0.1"
    port: int = Field(default=8790, ge=1, le=65535)
    log_level: str = "INFO"
    session_ttl_seconds: int = Field(default=86_400, ge=60)
    pairing_ttl_seconds: int = Field(default=600, ge=30, le=3600)
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

    @property
    def database_url(self) -> str:
        if self.database_url_override is not None:
            return self.database_url_override.get_secret_value()
        return f"sqlite+aiosqlite:///{self.data_dir / 'home_agent.db'}"

    def ensure_directories(self) -> None:
        self.data_dir.mkdir(parents=True, exist_ok=True)
