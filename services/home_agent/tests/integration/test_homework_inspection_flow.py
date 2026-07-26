from __future__ import annotations

from io import BytesIO
from typing import Any

from conftest import bootstrap, login
from fastapi.testclient import TestClient
from PIL import Image
from pydantic import SecretStr

from home_agent.services.homework_inspector import (
    InspectionProviderError,
    InspectionResult,
)


def image_bytes() -> bytes:
    output = BytesIO()
    Image.new("RGB", (48, 36), color=(250, 250, 250)).save(output, format="JPEG")
    return output.getvalue()


def setup_submission(client: TestClient) -> tuple[dict[str, str], dict, dict]:
    bootstrap(client)
    token = login(client)
    headers = {"Authorization": f"Bearer {token}"}
    child_response = client.post(
        "/api/v1/homework/members",
        headers=headers,
        json={"displayName": "大宝", "role": "child", "age": 10},
    )
    task_response = client.post(
        "/api/v1/homework/tasks",
        headers=headers,
        json={
            "childId": child_response.json()["id"],
            "title": "数学练习",
            "subject": "math",
            "taskDate": "2026-07-24",
            "instructions": "完成三道题并写过程",
            "referenceAnswer": "家长参考内容",
            "rubric": "步骤正确",
        },
    )
    submission_response = client.post(
        f"/api/v1/homework/tasks/{task_response.json()['id']}/submissions",
        headers=headers,
        files=[("files", ("page.jpg", image_bytes(), "image/jpeg"))],
    )
    assert submission_response.status_code == 201, submission_response.text
    return headers, task_response.json(), submission_response.json()


def configure_model(client: TestClient) -> None:
    client.app.state.settings.homework_model_enabled = True
    client.app.state.settings.homework_model_api_key = SecretStr("never-return-this-key")
    client.app.state.settings.homework_model_base_url = "https://api.moonshot.ai/v1"
    client.app.state.settings.homework_model_name = "kimi-k3"


class SuccessfulInspector:
    def __init__(self, result: InspectionResult) -> None:
        self.result = result
        self.calls = 0

    async def inspect(
        self, task: Any, assets: list[object], asset_service: object
    ) -> InspectionResult:
        self.calls += 1
        assert task.title == "数学练习"
        assert len(assets) == 1
        assert asset_service is not None
        return self.result


class FailingInspector:
    async def inspect(
        self, task: object, assets: list[object], asset_service: object
    ) -> InspectionResult:
        raise InspectionProviderError("model_rate_limited")


def inspection_result(*, confidence: float = 0.92) -> InspectionResult:
    return InspectionResult.model_validate(
        {
            "imageQuality": "clear",
            "summary": "第 2 题计算过程需要复核。",
            "confidence": confidence,
            "suggestedDecision": "retry",
            "items": [
                {
                    "location": "第 2 题",
                    "issue": "进位步骤可能遗漏。",
                    "hint": "先检查个位相加。",
                    "similarExample": "例如 18+27 的个位先算 8+7。",
                    "steps": ["圈出个位", "检查进位"],
                    "confidence": 0.9,
                }
            ],
        }
    )


def test_parent_explicitly_runs_inspection_without_changing_homework_state(
    client: TestClient,
) -> None:
    headers, task, submission = setup_submission(client)
    configure_model(client)
    fake = SuccessfulInspector(inspection_result())
    client.app.state.homework_inspector = fake

    status = client.get("/api/v1/homework/model-status", headers=headers)
    assert status.status_code == 200
    assert status.json() == {
        "enabled": True,
        "configured": True,
        "baseUrlHost": "api.moonshot.ai",
        "modelName": "kimi-k3",
    }

    response = client.post(
        f"/api/v1/homework/submissions/{submission['id']}/inspect", headers=headers
    )
    assert response.status_code == 201, response.text
    result = response.json()
    assert result["status"] == "completed"
    assert result["summary"].startswith("第 2 题")
    assert result["items"][0]["similarExample"].startswith("例如")
    assert "answer" not in str(result).lower()
    assert fake.calls == 1

    task_after = client.get(f"/api/v1/homework/tasks/{task['id']}", headers=headers)
    assert task_after.json()["status"] == "needs_parent_review"
    submission_after = client.get(
        f"/api/v1/homework/tasks/{task['id']}/submissions", headers=headers
    ).json()[0]
    assert submission_after["status"] == "needs_parent_review"
    assert submission_after["reviews"] == []

    history = client.get(
        f"/api/v1/homework/submissions/{submission['id']}/inspections", headers=headers
    )
    assert [item["id"] for item in history.json()] == [result["id"]]
    events = client.get(f"/api/v1/homework/events?taskId={task['id']}", headers=headers).json()
    assert [item["eventType"] for item in events][-2:] == [
        "homework.inspection.requested",
        "homework.inspection.completed",
    ]
    audit_text = client.get("/api/v1/audit-events", headers=headers).text
    assert "never-return-this-key" not in audit_text


def test_low_confidence_is_flagged_and_provider_failure_is_persisted(
    client: TestClient,
) -> None:
    headers, _task, submission = setup_submission(client)
    configure_model(client)
    client.app.state.homework_inspector = SuccessfulInspector(inspection_result(confidence=0.5))
    uncertain = client.post(
        f"/api/v1/homework/submissions/{submission['id']}/inspect", headers=headers
    )
    assert uncertain.status_code == 201
    assert uncertain.json()["status"] == "needs_parent_review"

    client.app.state.homework_inspector = FailingInspector()
    failed = client.post(
        f"/api/v1/homework/submissions/{submission['id']}/inspect", headers=headers
    )
    assert failed.status_code == 201
    assert failed.json()["status"] == "failed"
    assert failed.json()["errorCode"] == "model_rate_limited"
    assert failed.json()["summary"] is None


def test_disabled_missing_and_already_reviewed_inspections_are_rejected(
    client: TestClient,
) -> None:
    headers, _task, submission = setup_submission(client)
    disabled = client.get("/api/v1/homework/model-status", headers=headers)
    assert disabled.json()["enabled"] is False
    response = client.post(
        f"/api/v1/homework/submissions/{submission['id']}/inspect", headers=headers
    )
    assert response.status_code == 409
    assert response.json()["code"] == "homework_model_disabled"

    configure_model(client)
    missing = client.post(
        "/api/v1/homework/submissions/00000000-0000-4000-8000-000000000000/inspect",
        headers=headers,
    )
    assert missing.status_code == 404
    review = client.post(
        f"/api/v1/homework/submissions/{submission['id']}/review",
        headers=headers,
        json={"decision": "accept", "summary": "人工确认", "qualityLevel": "good"},
    )
    assert review.status_code == 200
    inspected = client.post(
        f"/api/v1/homework/submissions/{submission['id']}/inspect", headers=headers
    )
    assert inspected.status_code == 409
    assert inspected.json()["code"] == "invalid_submission_state"

    missing_history = client.get(
        "/api/v1/homework/submissions/00000000-0000-4000-8000-000000000000/inspections",
        headers=headers,
    )
    assert missing_history.status_code == 404
