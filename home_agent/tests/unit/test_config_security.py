from __future__ import annotations

from pathlib import Path

from pydantic import SecretStr

from home_agent.config import Settings
from home_agent.security import credential_hash, hash_password, random_credential, verify_password
from linux_room_node.config import NodeCredentials


def test_settings_defaults_and_environment(monkeypatch: object, tmp_path: Path) -> None:
    monkeypatch.setenv("HOME_AGENT_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("HOME_AGENT_PORT", "9001")
    settings = Settings()
    assert settings.data_dir == tmp_path
    assert settings.port == 9001
    assert settings.database_url.endswith("home_agent.db")
    settings.ensure_directories()
    assert tmp_path.is_dir()


def test_database_override_is_secret(tmp_path: Path) -> None:
    url = f"sqlite+aiosqlite:///{tmp_path / 'override.db'}"
    settings = Settings(database_url_override=url)
    assert settings.database_url == url
    assert url not in repr(settings)


def test_homework_model_defaults_and_api_key_are_private() -> None:
    settings = Settings(homework_model_api_key=SecretStr("private-model-key"))
    assert settings.homework_model_enabled is False
    assert settings.homework_model_base_url == "https://api.moonshot.ai/v1"
    assert settings.homework_model_name == "kimi-k3"
    assert settings.homework_model_api_key is not None
    assert settings.homework_model_api_key.get_secret_value() == "private-model-key"
    assert "private-model-key" not in repr(settings)


def test_password_and_credential_hashes_do_not_retain_plaintext() -> None:
    password = "a-very-long-password"
    password_hash = hash_password(password)
    assert password not in password_hash
    assert verify_password(password_hash, password)
    assert not verify_password(password_hash, "wrong-password")
    assert not verify_password("not-an-argon-hash", password)
    token = random_credential()
    assert len(token) >= 32
    assert token not in credential_hash(token)


def test_node_credentials_are_private_and_saved_with_owner_permissions(tmp_path: Path) -> None:
    path = tmp_path / "node.json"
    credentials = NodeCredentials.model_validate(
        {"nodeId": "node", "roomId": "room", "deviceKey": "top-secret-key"}
    )
    assert "top-secret-key" not in repr(credentials)
    credentials.save(path)
    assert path.stat().st_mode & 0o777 == 0o600
    loaded = NodeCredentials.load(path)
    assert loaded.device_key.get_secret_value() == "top-secret-key"
