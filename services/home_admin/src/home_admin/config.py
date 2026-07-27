from __future__ import annotations

from pydantic import AnyHttpUrl, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="HOME_ADMIN_",
        env_file=".env",
        extra="ignore",
    )

    host: str = "127.0.0.1"
    port: int = Field(default=8800, ge=1, le=65535)
    log_level: str = "INFO"
    home_agent_url: AnyHttpUrl = AnyHttpUrl("http://127.0.0.1:8790")
    upstream_timeout_seconds: float = Field(default=120.0, gt=0, le=600)
