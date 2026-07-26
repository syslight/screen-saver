#!/usr/bin/env python3
"""Bootstrap a local home_agent and issue reusable display-node credentials."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def request_json(
    base_url: str,
    path: str,
    *,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    authorization: str | None = None,
) -> tuple[int, dict[str, Any]]:
    data = None if body is None else json.dumps(body).encode()
    headers = {"Content-Type": "application/json"}
    if authorization:
        headers["Authorization"] = authorization
    request = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=data,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        return exc.code, json.loads(raw) if raw else {}


def secure_write(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as target:
        json.dump(payload, target, ensure_ascii=False, indent=2)
        target.write("\n")
    temporary.replace(path)
    path.chmod(0o600)


def login(base_url: str, operator: dict[str, Any]) -> str:
    status, response = request_json(
        base_url,
        "/api/v1/auth/login",
        method="POST",
        body={"username": operator["username"], "password": operator["password"]},
    )
    if status != 200:
        raise RuntimeError(f"home_agent login failed: HTTP {status}")
    return str(response["token"])


def ensure_operator(base_url: str, path: Path) -> tuple[dict[str, Any], str]:
    if path.exists():
        operator = json.loads(path.read_text(encoding="utf-8"))
        return operator, login(base_url, operator)

    operator = {
        "username": f"display-deployer-{secrets.token_hex(4)}",
        "password": secrets.token_urlsafe(32),
    }
    status, response = request_json(
        base_url,
        "/api/v1/bootstrap",
        method="POST",
        body={
            "householdName": "家庭智能相册",
            "timezone": "Asia/Shanghai",
            **operator,
        },
    )
    if status != 201:
        code = response.get("code", "unknown")
        raise RuntimeError(
            f"home_agent bootstrap failed: HTTP {status} ({code}); "
            f"provide the existing protected operator file at {path}"
        )
    operator["roomId"] = response["roomId"]
    secure_write(path, operator)
    return operator, login(base_url, operator)


def credential_valid(base_url: str, credential: dict[str, Any]) -> bool:
    node_id = credential.get("nodeId")
    device_key = credential.get("deviceKey")
    if not node_id or not device_key:
        return False
    status, _ = request_json(
        base_url,
        "/api/v1/media/status",
        authorization=f"Node {node_id}:{device_key}",
    )
    return status == 200


def provision_node(
    base_url: str,
    room_id: str,
    bearer: str,
    output: Path,
    *,
    name: str,
    platform: str,
) -> None:
    if output.exists():
        existing = json.loads(output.read_text(encoding="utf-8"))
        if credential_valid(base_url, existing):
            print(f"kept valid credentials: {output}")
            return
    status, pairing = request_json(
        base_url,
        "/api/v1/node-pairing-codes",
        method="POST",
        body={"roomId": room_id},
        authorization=f"Bearer {bearer}",
    )
    if status != 201:
        raise RuntimeError(f"pairing-code creation failed for {name}: HTTP {status}")
    status, credential = request_json(
        base_url,
        "/api/v1/nodes/pair",
        method="POST",
        body={"code": pairing["code"], "name": name, "platform": platform},
    )
    if status != 201:
        raise RuntimeError(f"node pairing failed for {name}: HTTP {status}")
    credential["agentUrl"] = base_url.rstrip("/")
    credential["name"] = name
    credential["platform"] = platform
    secure_write(output, credential)
    print(f"created credentials: {output}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent-url", default="http://127.0.0.1:8790")
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=Path.home() / ".local/share/family-home-agent/display-nodes",
    )
    parser.add_argument(
        "node",
        nargs="*",
        default=["ccl:天猫精灵智能相册:android-armv7", "rk3588:3588智能相册:linux-arm64"],
        help="node spec: file-stem:display-name:platform",
    )
    args = parser.parse_args()
    ready, _ = request_json(args.agent_url, "/health/ready")
    if ready != 200:
        raise RuntimeError(f"home_agent is not ready: HTTP {ready}")
    operator, bearer = ensure_operator(
        args.agent_url, args.state_dir / "deployment-operator.json"
    )
    for specification in args.node:
        stem, name, platform = specification.split(":", 2)
        provision_node(
            args.agent_url,
            str(operator["roomId"]),
            bearer,
            args.state_dir / f"{stem}.json",
            name=name,
            platform=platform,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
