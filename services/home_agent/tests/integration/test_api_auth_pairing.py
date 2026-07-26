from __future__ import annotations

from datetime import timedelta

from conftest import bootstrap, login, pair_node
from fastapi.testclient import TestClient
from sqlalchemy import select

from home_agent.domain.models import AuthSession, Node, PairingCode, User, utc_now
from home_agent.security import credential_hash


def test_health_bootstrap_login_second_parent_and_logout(client: TestClient) -> None:
    assert client.get("/health/live").json() == {"status": "ok"}
    assert client.get("/health/ready").status_code == 200
    created = bootstrap(client)
    duplicate = client.post(
        "/api/v1/bootstrap",
        json={
            "householdName": "另一家庭",
            "username": "other",
            "password": "another-password",
        },
    )
    assert duplicate.status_code == 409
    assert duplicate.json()["code"] == "already_bootstrapped"
    assert "requestId" in duplicate.json()

    bad = client.post(
        "/api/v1/auth/login", json={"username": "parent1", "password": "wrong-password"}
    )
    assert bad.status_code == 401
    token = login(client)
    headers = {"Authorization": f"Bearer {token}"}
    parent = client.post(
        "/api/v1/users",
        headers=headers,
        json={"username": "parent2", "password": "second-parent-password"},
    )
    assert parent.status_code == 201
    assert parent.json()["role"] == "parent"
    assert client.post("/api/v1/users", json={"username": "x", "password": "123"}).status_code in {
        401,
        422,
    }
    assert client.post("/api/v1/auth/logout", headers=headers).status_code == 204
    assert (
        client.post(
            "/api/v1/node-pairing-codes",
            headers=headers,
            json={"roomId": created["roomId"]},
        ).status_code
        == 401
    )


def test_pairing_is_one_time_and_database_contains_only_hashes(
    client: TestClient,
) -> None:
    created = bootstrap(client)
    token = login(client)
    headers = {"Authorization": f"Bearer {token}"}
    code_response = client.post(
        "/api/v1/node-pairing-codes",
        headers=headers,
        json={"roomId": created["roomId"]},
    )
    code = code_response.json()["code"]
    paired = client.post(
        "/api/v1/nodes/pair",
        json={"code": code, "name": "客厅节点", "platform": "linux"},
    )
    assert paired.status_code == 201
    device_key = paired.json()["deviceKey"]
    assert (
        client.post(
            "/api/v1/nodes/pair",
            json={"code": code, "name": "重复节点", "platform": "linux"},
        ).status_code
        == 409
    )
    assert (
        client.post(
            "/api/v1/nodes/pair",
            json={"code": "wrong", "name": "错误节点", "platform": "linux"},
        ).status_code
        == 401
    )

    async def inspect() -> None:
        async with client.app.state.session_factory() as session:
            pairing = await session.scalar(select(PairingCode))
            node = await session.scalar(select(Node))
            auth_session = await session.scalar(select(AuthSession))
            user = await session.scalar(select(User))
            assert pairing is not None and pairing.code_hash == credential_hash(code)
            assert node is not None and node.device_key_hash == credential_hash(device_key)
            assert auth_session is not None and token not in auth_session.token_hash
            assert user is not None and "correct-password" not in user.password_hash

    client.portal.call(inspect)


def test_expired_pairing_code_and_unknown_room(client: TestClient) -> None:
    created = bootstrap(client)
    token = login(client)
    headers = {"Authorization": f"Bearer {token}"}
    assert (
        client.post(
            "/api/v1/node-pairing-codes",
            headers=headers,
            json={"roomId": "00000000-0000-4000-8000-000000000000"},
        ).status_code
        == 404
    )
    code_response = client.post(
        "/api/v1/node-pairing-codes",
        headers=headers,
        json={"roomId": created["roomId"]},
    )
    code = code_response.json()["code"]

    async def expire() -> None:
        async with client.app.state.session_factory() as session:
            pairing = await session.scalar(
                select(PairingCode).where(PairingCode.code_hash == credential_hash(code))
            )
            assert pairing is not None
            pairing.expires_at = utc_now() - timedelta(seconds=1)
            await session.commit()

    client.portal.call(expire)
    response = client.post(
        "/api/v1/nodes/pair",
        json={"code": code, "name": "迟到节点", "platform": "linux"},
    )
    assert response.status_code == 410


def test_node_list_is_household_scoped_and_command_offline(client: TestClient) -> None:
    created = bootstrap(client)
    token = login(client)
    paired = pair_node(client, token, created["roomId"])
    headers = {"Authorization": f"Bearer {token}"}
    listed = client.get("/api/v1/nodes", headers=headers)
    assert listed.status_code == 200
    assert listed.json()[0]["id"] == paired["nodeId"]
    assert listed.json()[0]["status"] == "offline"
    assert client.get(f"/api/v1/nodes/{paired['nodeId']}", headers=headers).status_code == 200
    assert (
        client.get(
            "/api/v1/nodes/00000000-0000-4000-8000-000000000000", headers=headers
        ).status_code
        == 404
    )
    command = client.post(
        f"/api/v1/nodes/{paired['nodeId']}/commands",
        headers=headers,
        json={"commandName": "fake.echo", "arguments": {}},
    )
    assert command.status_code == 409
