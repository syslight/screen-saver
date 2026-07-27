from __future__ import annotations

from io import BytesIO
from pathlib import Path

from conftest import bootstrap, login
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import select

from home_agent.domain.models import SubmissionAsset


def image_bytes(image_format: str = "JPEG", *, size: tuple[int, int] = (32, 24)) -> bytes:
    buffer = BytesIO()
    Image.new("RGB", size, color=(80, 130, 190)).save(buffer, format=image_format)
    return buffer.getvalue()


def setup_family(client: TestClient) -> tuple[dict[str, str], dict[str, str], dict[str, str]]:
    created = bootstrap(client)
    token = login(client)
    headers = {"Authorization": f"Bearer {token}"}
    child = client.post(
        "/api/v1/homework/members",
        headers=headers,
        json={"displayName": "大宝", "role": "child", "age": 10},
    )
    assert child.status_code == 201, child.text
    return created, headers, child.json()


def create_task(
    client: TestClient, headers: dict[str, str], child_id: str, title: str = "数学练习"
) -> dict:
    response = client.post(
        "/api/v1/homework/tasks",
        headers=headers,
        json={
            "childId": child_id,
            "title": title,
            "subject": "math",
            "taskDate": "2026-07-24",
            "instructions": "完成第 1—6 题",
            "referenceAnswer": "1:A; 2:B",
            "rubric": "写出过程",
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def submit_jpeg(client: TestClient, headers: dict[str, str], task_id: str) -> dict:
    response = client.post(
        f"/api/v1/homework/tasks/{task_id}/submissions",
        headers=headers,
        files=[("files", ("homework.jpg", image_bytes(), "text/plain"))],
    )
    assert response.status_code == 201, response.text
    return response.json()


def test_parent_page_member_and_task_management(client: TestClient) -> None:
    assert client.get("/parent/").status_code == 404
    assert client.get("/api/v1/homework/members").status_code == 401

    _created, headers, child = setup_family(client)
    younger = client.post(
        "/api/v1/homework/members",
        headers=headers,
        json={"displayName": "小宝", "role": "child", "age": 5},
    )
    assert younger.status_code == 201
    assert (
        client.post(
            "/api/v1/homework/members",
            headers=headers,
            json={"displayName": "坏角色", "role": "admin", "age": 20},
        ).status_code
        == 400
    )
    duplicate = client.post(
        "/api/v1/homework/members",
        headers=headers,
        json={"displayName": "大宝", "role": "child", "age": 11},
    )
    assert duplicate.status_code == 409
    updated = client.patch(
        f"/api/v1/homework/members/{child['id']}",
        headers=headers,
        json={"age": 11},
    )
    assert updated.json()["age"] == 11
    assert (
        client.patch(
            "/api/v1/homework/members/00000000-0000-4000-8000-000000000000",
            headers=headers,
            json={"active": False},
        ).status_code
        == 404
    )

    parent_member = client.post(
        "/api/v1/homework/members",
        headers=headers,
        json={"displayName": "妈妈", "role": "parent", "age": 35},
    ).json()
    wrong_child = client.post(
        "/api/v1/homework/tasks",
        headers=headers,
        json={
            "childId": parent_member["id"],
            "title": "错误任务",
            "taskDate": "2026-07-24",
            "instructions": "不应创建",
        },
    )
    assert wrong_child.status_code == 404
    task = create_task(client, headers, child["id"])
    assert task["status"] == "pending"
    assert task["referenceAnswer"] == "1:A; 2:B"
    listed = client.get(
        "/api/v1/homework/tasks?date=2026-07-24&status=pending",
        headers=headers,
    )
    assert [item["id"] for item in listed.json()] == [task["id"]]
    assert client.get("/api/v1/homework/tasks?status=bad", headers=headers).status_code == 400
    edited = client.patch(
        f"/api/v1/homework/tasks/{task['id']}",
        headers=headers,
        json={"title": "数学练习（修改）", "dueAt": None},
    )
    assert edited.json()["title"].endswith("（修改）")
    started = client.post(f"/api/v1/homework/tasks/{task['id']}/start", headers=headers)
    assert started.json()["status"] == "in_progress"
    assert (
        client.post(f"/api/v1/homework/tasks/{task['id']}/start", headers=headers).status_code
        == 409
    )


def test_submission_asset_auth_review_and_event_history(client: TestClient) -> None:
    _created, headers, child = setup_family(client)
    task = create_task(client, headers, child["id"])
    submission = submit_jpeg(client, headers, task["id"])
    assert submission["attemptNo"] == 1
    assert submission["status"] == "needs_parent_review"
    asset = submission["assets"][0]
    assert asset["mediaType"] == "image/jpeg"
    assert client.get(asset["url"]).status_code == 401
    downloaded = client.get(asset["url"], headers=headers)
    assert downloaded.status_code == 200
    assert downloaded.headers["content-type"].startswith("image/jpeg")
    assert downloaded.content == image_bytes()
    task_after = client.get(f"/api/v1/homework/tasks/{task['id']}", headers=headers)
    assert task_after.json()["status"] == "needs_parent_review"
    assert (
        client.patch(
            f"/api/v1/homework/tasks/{task['id']}", headers=headers, json={"title": "不能改"}
        ).status_code
        == 409
    )
    assert (
        client.post(
            f"/api/v1/homework/tasks/{task['id']}/submissions",
            headers=headers,
            files=[("files", ("again.png", image_bytes("PNG"), "image/png"))],
        ).status_code
        == 409
    )

    bad_review = client.post(
        f"/api/v1/homework/submissions/{submission['id']}/review",
        headers=headers,
        json={"decision": "maybe", "summary": "不知道", "qualityLevel": "unknown"},
    )
    assert bad_review.status_code == 400
    review = client.post(
        f"/api/v1/homework/submissions/{submission['id']}/review",
        headers=headers,
        json={
            "decision": "accept",
            "summary": "整体完成良好",
            "qualityLevel": "good",
            "items": [{"label": "第1题", "verdict": "correct"}],
        },
    )
    assert review.status_code == 200
    assert review.json()["qualityLevel"] == "good"
    assert (
        client.post(
            f"/api/v1/homework/submissions/{submission['id']}/review",
            headers=headers,
            json={"decision": "accept", "summary": "重复", "qualityLevel": "good"},
        ).status_code
        == 409
    )
    completed = client.get(f"/api/v1/homework/tasks/{task['id']}", headers=headers)
    assert completed.json()["status"] == "completed"
    events = client.get(f"/api/v1/homework/events?taskId={task['id']}", headers=headers).json()
    assert [item["eventType"] for item in events] == [
        "homework.task.created",
        "homework.submission.created",
        "homework.review.accept",
    ]


def test_retry_creates_second_immutable_attempt_and_cancel(client: TestClient) -> None:
    _created, headers, child = setup_family(client)
    task = create_task(client, headers, child["id"], "需要重做的作业")
    first = submit_jpeg(client, headers, task["id"])
    retried = client.post(
        f"/api/v1/homework/submissions/{first['id']}/review",
        headers=headers,
        json={"decision": "retry", "summary": "第 3 题重做", "qualityLevel": "needs_revision"},
    )
    assert retried.status_code == 200
    second = submit_jpeg(client, headers, task["id"])
    assert second["attemptNo"] == 2
    history = client.get(f"/api/v1/homework/tasks/{task['id']}/submissions", headers=headers).json()
    assert [item["attemptNo"] for item in history] == [2, 1]
    assert history[1]["status"] == "changes_requested"
    assert history[1]["assets"][0]["id"] != history[0]["assets"][0]["id"]

    another = create_task(client, headers, child["id"], "取消的作业")
    cancelled = client.post(f"/api/v1/homework/tasks/{another['id']}/cancel", headers=headers)
    assert cancelled.json()["status"] == "cancelled"
    assert (
        client.post(f"/api/v1/homework/tasks/{another['id']}/cancel", headers=headers).status_code
        == 409
    )


def test_image_validation_limits_quota_and_path_protection(
    client: TestClient, tmp_path: Path
) -> None:
    _created, headers, child = setup_family(client)
    task = create_task(client, headers, child["id"])
    corrupt = client.post(
        f"/api/v1/homework/tasks/{task['id']}/submissions",
        headers=headers,
        files=[("files", ("fake.jpg", b"not an image", "image/jpeg"))],
    )
    assert corrupt.status_code == 400
    gif = client.post(
        f"/api/v1/homework/tasks/{task['id']}/submissions",
        headers=headers,
        files=[("files", ("image.gif", image_bytes("GIF"), "image/gif"))],
    )
    assert gif.status_code == 400
    too_many = client.post(
        f"/api/v1/homework/tasks/{task['id']}/submissions",
        headers=headers,
        files=[("files", (f"{index}.jpg", image_bytes(), "image/jpeg")) for index in range(7)],
    )
    assert too_many.status_code == 413
    oversized = client.post(
        f"/api/v1/homework/tasks/{task['id']}/submissions",
        headers=headers,
        files=[
            (
                "files",
                (
                    "huge.jpg",
                    b"x" * (client.app.state.settings.homework_max_file_bytes + 1),
                    "image/jpeg",
                ),
            )
        ],
    )
    assert oversized.status_code == 413
    assert not list((tmp_path / "homework" / "tmp").glob("*.part"))

    client.app.state.settings.homework_quota_bytes = 1
    quota = client.post(
        f"/api/v1/homework/tasks/{task['id']}/submissions",
        headers=headers,
        files=[("files", ("valid.webp", image_bytes("WEBP"), "image/webp"))],
    )
    assert quota.status_code == 413
    client.app.state.settings.homework_quota_bytes = 5 * 1024 * 1024 * 1024
    submission = submit_jpeg(client, headers, task["id"])
    asset_id = submission["assets"][0]["id"]

    async def corrupt_path() -> None:
        async with client.app.state.session_factory() as session:
            asset = await session.scalar(
                select(SubmissionAsset).where(SubmissionAsset.id == asset_id)
            )
            assert asset is not None
            asset.local_path = "../outside.jpg"
            await session.commit()

    client.portal.call(corrupt_path)
    assert client.get(f"/api/v1/homework/assets/{asset_id}", headers=headers).status_code == 404
