from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from io import BytesIO

from conftest import bootstrap, login
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import select

from home_agent.domain.models import StudentDevice, StudentPairingCode, utc_now
from home_agent.security import credential_hash


def _image_bytes() -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (32, 24), color=(40, 120, 200)).save(buffer, format="JPEG")
    return buffer.getvalue()


def _setup(client: TestClient) -> tuple[dict[str, str], dict, dict]:
    bootstrap(client)
    parent_headers = {"Authorization": f"Bearer {login(client)}"}
    older = client.post(
        "/api/v1/homework/members",
        headers=parent_headers,
        json={"displayName": "大宝", "role": "child", "age": 10},
    ).json()
    younger = client.post(
        "/api/v1/homework/members",
        headers=parent_headers,
        json={"displayName": "小宝", "role": "child", "age": 5},
    ).json()
    return parent_headers, older, younger


def _create_task(
    client: TestClient,
    parent_headers: dict[str, str],
    child_id: str,
    *,
    title: str,
    answer: str,
) -> dict:
    response = client.post(
        "/api/v1/homework/tasks",
        headers=parent_headers,
        json={
            "childId": child_id,
            "title": title,
            "subject": "math",
            "taskDate": "2026-07-24",
            "instructions": "完成第 1—6 题",
            "referenceAnswer": answer,
            "rubric": "写出计算过程",
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _pair(
    client: TestClient, parent_headers: dict[str, str], child_id: str
) -> tuple[dict, dict[str, str], str]:
    code_response = client.post(
        "/api/v1/homework/student-pairing-codes",
        headers=parent_headers,
        json={"childId": child_id},
    )
    assert code_response.status_code == 201, code_response.text
    code = code_response.json()["code"]
    paired = client.post(
        "/api/v1/student/pair",
        json={"code": code, "name": "学习平板", "platform": "android"},
    )
    assert paired.status_code == 201, paired.text
    return paired.json(), {"Authorization": f"Student {paired.json()['deviceKey']}"}, code


def test_student_pairing_hashes_one_time_revoke_and_expiry(client: TestClient) -> None:
    parent_headers, older, _younger = _setup(client)
    assert (
        client.post(
            "/api/v1/homework/student-pairing-codes", json={"childId": older["id"]}
        ).status_code
        == 401
    )
    paired, student_headers, code = _pair(client, parent_headers, older["id"])
    assert len(code) == 8 and code.isalnum() and code == code.upper()
    device_key = paired["deviceKey"]
    assert paired["childName"] == "大宝"
    assert client.get("/api/v1/student/me", headers=student_headers).json()["childName"] == "大宝"
    assert (
        client.post(
            "/api/v1/student/pair",
            json={"code": code, "name": "重复平板", "platform": "android"},
        ).status_code
        == 409
    )
    assert client.get("/api/v1/student/me").status_code == 401
    assert (
        client.post(
            "/api/v1/student/pair",
            json={"code": "WRONG234", "name": "错误平板", "platform": "android"},
        ).status_code
        == 401
    )

    async def inspect_hashes() -> None:
        async with client.app.state.session_factory() as session:
            pairing = await session.scalar(select(StudentPairingCode))
            device = await session.scalar(select(StudentDevice))
            assert pairing is not None and pairing.code_hash == credential_hash(code)
            assert device is not None and device.device_key_hash == credential_hash(device_key)
            assert code not in pairing.code_hash
            assert device_key not in device.device_key_hash

    client.portal.call(inspect_hashes)
    devices = client.get("/api/v1/homework/student-devices", headers=parent_headers).json()
    assert devices[0]["childId"] == older["id"]
    revoked = client.post(
        f"/api/v1/homework/student-devices/{paired['deviceId']}/revoke",
        headers=parent_headers,
    )
    assert revoked.status_code == 200
    assert revoked.json()["active"] is False
    assert client.get("/api/v1/student/me", headers=student_headers).status_code == 401

    racing = client.post(
        "/api/v1/homework/student-pairing-codes",
        headers=parent_headers,
        json={"childId": older["id"]},
    ).json()

    def consume_racing_code(name: str) -> int:
        return client.post(
            "/api/v1/student/pair",
            json={"code": racing["code"], "name": name, "platform": "android"},
        ).status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        statuses = list(executor.map(consume_racing_code, ["并发平板 A", "并发平板 B"]))
    assert sorted(statuses) == [201, 409]

    expiring = client.post(
        "/api/v1/homework/student-pairing-codes",
        headers=parent_headers,
        json={"childId": older["id"]},
    ).json()

    async def expire_code() -> None:
        async with client.app.state.session_factory() as session:
            row = await session.scalar(
                select(StudentPairingCode).where(
                    StudentPairingCode.code_hash == credential_hash(expiring["code"])
                )
            )
            assert row is not None
            row.expires_at = utc_now() - timedelta(seconds=1)
            await session.commit()

    client.portal.call(expire_code)
    expired = client.post(
        "/api/v1/student/pair",
        json={"code": expiring["code"], "name": "迟到平板", "platform": "android"},
    )
    assert expired.status_code == 410


def test_student_isolation_hides_answers_and_runs_review_cycle(client: TestClient) -> None:
    parent_headers, older, younger = _setup(client)
    own_task = _create_task(
        client,
        parent_headers,
        older["id"],
        title="大宝数学",
        answer="秘密答案 42",
    )
    other_task = _create_task(
        client,
        parent_headers,
        younger["id"],
        title="小宝数学",
        answer="另一个秘密答案",
    )
    _paired, student_headers, _code = _pair(client, parent_headers, older["id"])

    listed_response = client.get("/api/v1/student/homework/tasks", headers=student_headers)
    assert listed_response.status_code == 200
    assert [item["id"] for item in listed_response.json()] == [own_task["id"]]
    assert "秘密答案" not in listed_response.text
    assert "referenceAnswer" not in listed_response.text
    assert "rubric" not in listed_response.text
    assert (
        client.get(
            f"/api/v1/student/homework/tasks/{other_task['id']}", headers=student_headers
        ).status_code
        == 404
    )
    assert (
        client.post(
            f"/api/v1/student/homework/tasks/{other_task['id']}/start",
            headers=student_headers,
        ).status_code
        == 404
    )

    started = client.post(
        f"/api/v1/student/homework/tasks/{own_task['id']}/start",
        headers=student_headers,
    )
    assert started.status_code == 200
    assert started.json()["status"] == "in_progress"
    assert (
        client.post(
            f"/api/v1/student/homework/tasks/{own_task['id']}/start",
            headers=student_headers,
        ).status_code
        == 409
    )
    submitted = client.post(
        f"/api/v1/student/homework/tasks/{own_task['id']}/submissions",
        headers=student_headers,
        files=[("files", ("page-1.jpg", _image_bytes(), "image/jpeg"))],
    )
    assert submitted.status_code == 201, submitted.text
    assert submitted.json()["attemptNo"] == 1
    first_id = submitted.json()["id"]
    retry = client.post(
        f"/api/v1/homework/submissions/{first_id}/review",
        headers=parent_headers,
        json={
            "decision": "retry",
            "summary": "第 3 题请重新检查计算过程",
            "qualityLevel": "needs_revision",
            "items": [{"answer": "不应发给学生的结构化答案"}],
        },
    )
    assert retry.status_code == 200
    history = client.get(
        f"/api/v1/student/homework/tasks/{own_task['id']}/submissions",
        headers=student_headers,
    )
    assert history.status_code == 200
    assert history.json()[0]["reviews"][0]["summary"].startswith("第 3 题")
    assert "不应发给学生的结构化答案" not in history.text

    second = client.post(
        f"/api/v1/student/homework/tasks/{own_task['id']}/submissions",
        headers=student_headers,
        files=[("files", ("page-2.jpg", _image_bytes(), "image/jpeg"))],
    )
    assert second.status_code == 201
    assert second.json()["attemptNo"] == 2
    accepted = client.post(
        f"/api/v1/homework/submissions/{second.json()['id']}/review",
        headers=parent_headers,
        json={
            "decision": "accept",
            "summary": "完成得很好",
            "qualityLevel": "good",
        },
    )
    assert accepted.status_code == 200
    completed = client.get(
        f"/api/v1/student/homework/tasks/{own_task['id']}", headers=student_headers
    )
    assert completed.json()["status"] == "completed"
    assert (
        client.post(
            f"/api/v1/student/homework/tasks/{own_task['id']}/submissions",
            headers=student_headers,
            files=[("files", ("late.jpg", _image_bytes(), "image/jpeg"))],
        ).status_code
        == 409
    )
