from __future__ import annotations

import base64

from conftest import bootstrap, login
from fastapi.testclient import TestClient


def test_provider_admin_requires_parent_and_persists_selection(client: TestClient) -> None:
    assert client.get("/admin/").status_code == 404
    assert client.get("/parent/").status_code == 404
    assert client.get("/api/v1/admin/providers").status_code == 401
    bootstrap(client)
    token = login(client)
    headers = {"Authorization": f"Bearer {token}"}

    status = client.get("/api/v1/admin/providers", headers=headers)
    assert status.status_code == 200
    assert status.json()["selection"] == {"asr": "volcano", "tts": "volcano", "llm": "glm"}
    assert status.json()["providers"]["asr"][0]["state"] == "unconfigured"

    updated = client.put(
        "/api/v1/admin/providers/selection",
        headers=headers,
        json={"asr": "local", "tts": "piper", "llm": "kimi"},
    )
    assert updated.status_code == 200
    assert updated.json()["selection"] == {"asr": "local", "tts": "piper", "llm": "kimi"}
    audit = client.get("/api/v1/audit-events", headers=headers).json()
    assert audit[0]["action"] == "voice.providers.select"
    assert "api" not in str(audit[0]["payload"]).lower()


def test_provider_configuration_is_scoped_redacted_and_audited(
    client: TestClient,
) -> None:
    assert (
        client.put(
            "/api/v1/admin/providers/asr/volcano/configuration",
            json={"values": {"apiKey": "must-not-be-stored"}},
        ).status_code
        == 401
    )
    bootstrap(client)
    token = login(client)
    headers = {"Authorization": f"Bearer {token}"}

    response = client.put(
        "/api/v1/admin/providers/asr/volcano/configuration",
        headers=headers,
        json={
            "values": {
                "authMode": "app_key",
                "apiKey": "volcano-api-private",
                "model": "bigmodel-custom",
                "language": "yue",
            }
        },
    )
    assert response.status_code == 200
    encoded = response.text
    assert "volcano-api-private" not in encoded
    volcano = response.json()["providers"]["asr"][0]
    fields = {item["name"]: item for item in volcano["fields"]}
    assert fields["authMode"]["value"] == "app_key"
    assert fields["apiKey"]["hint"] == "••••vate"
    assert fields["model"]["value"] == "bigmodel-custom"
    assert fields["language"]["value"] == "yue"

    tts = client.put(
        "/api/v1/admin/providers/tts/volcano/configuration",
        headers=headers,
        json={
            "values": {
                "apiKey": "tts-api-private",
                "voice": "tts-family-voice",
                "speechRate": 12,
            }
        },
    )
    assert tts.status_code == 200
    assert "tts-api-private" not in tts.text
    tts_provider = tts.json()["providers"]["tts"][0]
    assert tts_provider["voice"] == "tts-family-voice"
    tts_fields = {item["name"]: item for item in tts_provider["fields"]}
    assert tts_fields["apiKey"]["hint"] == "••••vate"
    assert tts_fields["apiKey"]["source"] == "managed"
    assert tts_fields["speechRate"]["value"] == 12
    audit = client.get("/api/v1/audit-events", headers=headers).json()[0]
    assert audit["action"] == "voice.provider.configuration.update"
    assert audit["resourceId"] == "tts.volcano"
    assert "private" not in str(audit["payload"])

    cleared = client.put(
        "/api/v1/admin/providers/asr/volcano/configuration",
        headers=headers,
        json={"clear": ["apiKey"]},
    )
    assert cleared.status_code == 200
    asr_provider = cleared.json()["providers"]["asr"][0]
    credential = next(item for item in asr_provider["fields"] if item["name"] == "apiKey")
    assert credential["configured"] is False
    assert "hint" not in credential


def test_provider_configuration_rejects_update_and_clear_overlap(client: TestClient) -> None:
    bootstrap(client)
    token = login(client)
    response = client.put(
        "/api/v1/admin/providers/llm/glm/configuration",
        headers={"Authorization": f"Bearer {token}"},
        json={"values": {"apiKey": "new-value"}, "clear": ["apiKey"]},
    )
    assert response.status_code == 422
    assert response.json()["code"] == "invalid_provider_configuration"

    unknown = client.put(
        "/api/v1/admin/providers/image/unknown/configuration",
        headers={"Authorization": f"Bearer {token}"},
        json={"values": {}},
    )
    assert unknown.status_code == 422
    assert unknown.json()["code"] == "invalid_provider"


def test_provider_admin_reports_unconfigured_check_without_secrets(client: TestClient) -> None:
    bootstrap(client)
    token = login(client)
    response = client.post(
        "/api/v1/admin/providers/check",
        headers={"Authorization": f"Bearer {token}"},
        json={"kind": "asr", "name": "openai"},
    )
    assert response.status_code == 409
    assert response.json()["code"] == "provider_not_configured"


class BrokenRecognizer:
    configured = True

    async def transcribe(self, pcm: bytes) -> str:
        raise ValueError("raw provider response must stay private")


class TestRecognizer:
    configured = True

    async def transcribe(self, pcm: bytes) -> str:
        assert pcm == b"\x01\x00\x02\x00"
        return "测试识别内容"


class TestSynthesizer:
    configured = True

    async def synthesize(self, text: str) -> bytes:
        assert text == "请播放测试语音"
        return b"RIFF-test-audio"


class TestLlm:
    configured = True

    async def reply(self, transcript: str, *, node_id: str) -> str:
        assert transcript == "请介绍你自己"
        assert node_id == "provider-test-glm"
        return "我是家庭智能助手。"

    def clear(self, node_id: str) -> None:
        assert node_id == "provider-test-glm"


def test_provider_interactive_tests_return_transcript_audio_and_reply(
    client: TestClient,
) -> None:
    bootstrap(client)
    token = login(client)
    headers = {"Authorization": f"Bearer {token}"}
    registry = client.app.state.voice_providers
    registry.asr["volcano"] = TestRecognizer()
    registry.tts["volcano"] = TestSynthesizer()
    registry.llm["glm"] = TestLlm()

    asr = client.post(
        "/api/v1/admin/providers/test",
        headers=headers,
        json={
            "kind": "asr",
            "name": "volcano",
            "audioBase64": base64.b64encode(b"\x01\x00\x02\x00").decode(),
        },
    )
    assert asr.status_code == 200
    assert asr.json()["text"] == "测试识别内容"

    tts = client.post(
        "/api/v1/admin/providers/test",
        headers=headers,
        json={"kind": "tts", "name": "volcano", "text": "请播放测试语音"},
    )
    assert tts.status_code == 200
    assert base64.b64decode(tts.json()["audioBase64"]) == b"RIFF-test-audio"
    assert tts.json()["audioMimeType"] == "audio/wav"

    llm = client.post(
        "/api/v1/admin/providers/test",
        headers=headers,
        json={"kind": "llm", "name": "glm", "text": "请介绍你自己"},
    )
    assert llm.status_code == 200
    assert llm.json()["text"] == "我是家庭智能助手。"


def test_provider_admin_normalizes_provider_failure(client: TestClient) -> None:
    bootstrap(client)
    token = login(client)
    client.app.state.voice_providers.asr["openai"] = BrokenRecognizer()
    response = client.post(
        "/api/v1/admin/providers/check",
        headers={"Authorization": f"Bearer {token}"},
        json={"kind": "asr", "name": "openai"},
    )
    assert response.status_code == 200
    encoded = response.text
    assert '"state":"error"' in encoded
    assert "raw provider response" not in encoded

    unknown = client.post(
        "/api/v1/admin/providers/check",
        headers={"Authorization": f"Bearer {token}"},
        json={"kind": "asr", "name": "unknown"},
    )
    assert unknown.status_code == 422
    assert unknown.json()["code"] == "invalid_provider"
