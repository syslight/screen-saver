from __future__ import annotations

import httpx
from fastapi.testclient import TestClient

from home_admin.app import create_app
from home_admin.config import Settings


def _transport() -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/health/ready":
            return httpx.Response(200, json={"status": "ready"})
        return httpx.Response(
            200,
            json={
                "method": request.method,
                "path": request.url.path,
                "authorization": request.headers.get("authorization"),
            },
        )

    return httpx.MockTransport(handler)


def test_serves_home_admin_and_has_no_parent_route() -> None:
    with TestClient(create_app(Settings(), transport=_transport())) as client:
        page = client.get("/")
        assert page.status_code == 200
        assert page.headers["cache-control"] == "no-store, max-age=0"
        assert "HomeAdmin" in page.text
        assert "data-provider-config" in page.text
        assert "credential-status" in page.text
        assert "data-secret-hint" in page.text
        assert "raw===field.dataset.secretHint" in page.text
        assert "实际语音识别测试" in page.text
        assert "实际语音合成测试" in page.text
        assert "实际模型对话测试" in page.text
        assert "audioBase64" in page.text
        assert "输入新值可替换；留空保留现有值" in page.text
        assert "field.required && !(field.secret && field.configured)" in page.text
        assert "providerCredentialsForm" not in page.text
        assert client.get("/parent/").status_code == 404


def test_proxies_api_and_authorization_to_home_agent() -> None:
    with TestClient(create_app(Settings(), transport=_transport())) as client:
        response = client.put(
            "/api/v1/admin/providers/selection",
            headers={"Authorization": "Bearer private-token"},
            json={"asr": "volcano", "tts": "volcano", "llm": "glm"},
        )
        assert response.status_code == 200
        assert response.headers["cache-control"] == "no-store, max-age=0"
        assert response.json() == {
            "method": "PUT",
            "path": "/api/v1/admin/providers/selection",
            "authorization": "Bearer private-token",
        }


def test_readiness_tracks_home_agent() -> None:
    with TestClient(create_app(Settings(), transport=_transport())) as client:
        assert client.get("/health/ready").json() == {
            "status": "ready",
            "homeAgent": True,
        }
