from __future__ import annotations

import json
import os
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, SecretStr


class NodeCredentials(BaseModel):
    model_config = ConfigDict(extra="forbid")

    node_id: str = Field(alias="nodeId")
    room_id: str = Field(alias="roomId")
    device_key: SecretStr = Field(alias="deviceKey", repr=False)

    @classmethod
    def load(cls, path: Path) -> NodeCredentials:
        return cls.model_validate_json(path.read_text(encoding="utf-8"))

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = self.model_dump(mode="json", by_alias=True)
        payload["deviceKey"] = self.device_key.get_secret_value()
        path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        os.chmod(path, 0o600)


def default_credentials_path() -> Path:
    return Path.home() / ".local" / "share" / "family-home-agent" / "fake-node.json"
