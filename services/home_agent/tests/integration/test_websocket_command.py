from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor

from conftest import bootstrap, login, pair_node
from fastapi.testclient import TestClient

from home_agent.protocol.envelope import make_envelope
from home_agent.protocol.messages import (
    CapabilitiesPayload,
    Capability,
    CommandResultPayload,
    HeartbeatPayload,
    HelloPayload,
)


def _message(message_type: str, payload: object, paired: dict[str, str], sequence: int) -> dict:
    return make_envelope(
        message_type,
        payload,  # type: ignore[arg-type]
        sequence=sequence,
        node_id=paired["nodeId"],
        room_id=paired["roomId"],
    ).json_dict()


def test_wrong_device_key_is_rejected(client: TestClient) -> None:
    created = bootstrap(client)
    token = login(client)
    paired = pair_node(client, token, created["roomId"])
    with client.websocket_connect("/api/v1/nodes/ws") as socket:
        socket.send_json(
            _message(
                "node.hello",
                HelloPayload(
                    device_key="wrong-device-key-with-enough-length",
                    software_version="test",
                    platform="fake",
                    media_protocol_version=0,
                ),
                paired,
                1,
            )
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["payload"]["code"] == "node_auth_failed"


def test_capabilities_heartbeat_command_and_disconnect(client: TestClient) -> None:
    created = bootstrap(client)
    token = login(client)
    paired = pair_node(client, token, created["roomId"])
    headers = {"Authorization": f"Bearer {token}"}
    with client.websocket_connect("/api/v1/nodes/ws") as socket:
        socket.send_json(
            _message(
                "node.hello",
                HelloPayload(
                    device_key=paired["deviceKey"],
                    software_version="test",
                    platform="fake",
                    media_protocol_version=0,
                ),
                paired,
                1,
            )
        )
        socket.send_json(
            _message(
                "node.capabilities",
                CapabilitiesPayload(
                    capabilities=[
                        Capability(
                            capability_id="camera-1",
                            type="camera",
                            status="online",
                            properties={"supportsStill": True},
                            commands=["fake.set_status"],
                        )
                    ]
                ),
                paired,
                2,
            )
        )
        socket.send_json(_message("heartbeat.ping", HeartbeatPayload(nonce="sync"), paired, 3))
        pong = socket.receive_json()
        assert pong["type"] == "heartbeat.pong"

        node = client.get(f"/api/v1/nodes/{paired['nodeId']}", headers=headers).json()
        assert node["status"] == "online"
        assert node["capabilities"][0]["capabilityId"] == "camera-1"

        with ThreadPoolExecutor(max_workers=1) as executor:
            response_future = executor.submit(
                client.post,
                f"/api/v1/nodes/{paired['nodeId']}/commands",
                headers=headers,
                json={"commandName": "fake.echo", "arguments": {"text": "hello"}},
            )
            command = socket.receive_json()
            assert command["type"] == "command.request"
            socket.send_json(
                _message(
                    "command.result",
                    CommandResultPayload(
                        request_message_id=command["messageId"],
                        success=True,
                        result={"echo": command["payload"]["arguments"]},
                    ),
                    paired,
                    4,
                )
            )
            response = response_future.result(timeout=3)
        assert response.status_code == 200
        assert response.json()["result"] == {"echo": {"text": "hello"}}

        socket.send_json(
            _message("heartbeat.ping", HeartbeatPayload(nonce="old-sequence"), paired, 4)
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["payload"]["code"] == "invalid_sequence"

    node = {}
    for _ in range(100):
        node = client.get(f"/api/v1/nodes/{paired['nodeId']}", headers=headers).json()
        if node["status"] == "offline":
            break
        time.sleep(0.01)
    assert node["status"] == "offline"
    audit = client.get("/api/v1/audit-events", headers=headers).json()
    actions = {item["action"] for item in audit}
    assert {"node.connect", "node.disconnect", "node.command"} <= actions
