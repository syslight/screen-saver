from __future__ import annotations

import asyncio
import secrets
from typing import Any

from anyio import CancelScope
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from home_agent.domain.models import Node
from home_agent.protocol.envelope import (
    Envelope,
    ProtocolValidationError,
    make_envelope,
    parse_envelope,
)
from home_agent.protocol.messages import (
    CapabilitiesPayload,
    CommandResultPayload,
    ErrorPayload,
    HeartbeatPayload,
    HelloPayload,
    NodeEventPayload,
)
from home_agent.repositories.audit import AuditRepository
from home_agent.repositories.node import NodeRepository
from home_agent.security import credential_hash
from home_agent.services.node_registry import NodeConnection

router = APIRouter(tags=["node-websocket"])


async def _send_error(
    websocket: WebSocket,
    error: ProtocolValidationError,
    *,
    sequence: int,
    node_id: str | None = None,
    room_id: str | None = None,
) -> None:
    envelope = make_envelope(
        "error",
        ErrorPayload(code=error.code, message=error.message, details=error.details),
        sequence=sequence,
        node_id=node_id,
        room_id=room_id,
    )
    await websocket.send_json(envelope.json_dict())


async def _authenticate_hello(websocket: WebSocket) -> tuple[Envelope, HelloPayload, Node]:
    settings = websocket.app.state.settings
    raw: Any = await asyncio.wait_for(
        websocket.receive_json(), timeout=settings.hello_timeout_seconds
    )
    if not isinstance(raw, dict):
        raise ProtocolValidationError("invalid_envelope", "Message must be a JSON object")
    parsed = parse_envelope(raw)
    if parsed.envelope.type != "node.hello" or not isinstance(parsed.payload, HelloPayload):
        raise ProtocolValidationError("hello_required", "The first message must be node.hello")
    if parsed.envelope.node_id is None or parsed.envelope.room_id is None:
        raise ProtocolValidationError("invalid_hello", "nodeId and roomId are required")
    async with websocket.app.state.session_factory() as session:
        repository = NodeRepository(session)
        node = await repository.node_by_id(parsed.envelope.node_id)
        if (
            node is None
            or not node.active
            or node.room_id != parsed.envelope.room_id
            or not secrets.compare_digest(
                node.device_key_hash, credential_hash(parsed.payload.device_key)
            )
        ):
            raise ProtocolValidationError("node_auth_failed", "Node authentication failed")
        return parsed.envelope, parsed.payload, node


@router.websocket("/api/v1/nodes/ws")
async def node_websocket(websocket: WebSocket) -> None:
    await websocket.accept()
    connection: NodeConnection | None = None
    node: Node | None = None
    try:
        hello, _payload, node = await _authenticate_hello(websocket)
        connection = NodeConnection(node.id, node.room_id, websocket)
        previous = await websocket.app.state.node_registry.connect(connection)
        async with websocket.app.state.session_factory() as session:
            repository = NodeRepository(session)
            current = await repository.node_by_id(node.id)
            if current is not None:
                await repository.set_status(current, "online")
            await AuditRepository(session).add(
                household_id=node.household_id,
                actor_type="node",
                actor_id=node.id,
                action="node.connect",
                resource_type="node",
                resource_id=node.id,
                payload={"replacedConnection": previous is not None},
            )
            await session.commit()
        last_sequence = hello.sequence
        error_sequence = 0
        while True:
            try:
                raw = await asyncio.wait_for(
                    websocket.receive_json(),
                    timeout=websocket.app.state.settings.heartbeat_timeout_seconds,
                )
                if not isinstance(raw, dict):
                    raise ProtocolValidationError(
                        "invalid_envelope", "Message must be a JSON object"
                    )
                parsed = parse_envelope(raw)
                if parsed.envelope.node_id != node.id or parsed.envelope.room_id != node.room_id:
                    raise ProtocolValidationError(
                        "identity_mismatch", "Envelope identity does not match the connection"
                    )
                if parsed.envelope.sequence <= last_sequence:
                    raise ProtocolValidationError(
                        "invalid_sequence", "Sequence must increase on a connection"
                    )
                last_sequence = parsed.envelope.sequence
                if isinstance(parsed.payload, HeartbeatPayload):
                    if parsed.envelope.type == "heartbeat.ping":
                        await connection.send(
                            make_envelope(
                                "heartbeat.pong",
                                parsed.payload,
                                sequence=connection.next_sequence(),
                                node_id=node.id,
                                room_id=node.room_id,
                            )
                        )
                elif isinstance(parsed.payload, CapabilitiesPayload):
                    capability_data = [
                        item.model_dump(mode="json", by_alias=True)
                        for item in parsed.payload.capabilities
                    ]
                    async with websocket.app.state.session_factory() as session:
                        await NodeRepository(session).replace_capabilities(node.id, capability_data)
                        await session.commit()
                elif isinstance(parsed.payload, CommandResultPayload):
                    websocket.app.state.node_registry.resolve_result(node.id, parsed.payload)
                elif isinstance(parsed.payload, NodeEventPayload):
                    async with websocket.app.state.session_factory() as session:
                        await AuditRepository(session).add(
                            household_id=node.household_id,
                            actor_type="node",
                            actor_id=node.id,
                            action="node.event",
                            resource_type="node",
                            resource_id=node.id,
                            payload={"eventName": parsed.payload.event_name},
                        )
                        await session.commit()
                else:
                    raise ProtocolValidationError(
                        "unexpected_message", "Message is not accepted from a node"
                    )
            except ProtocolValidationError as exc:
                error_sequence += 1
                await _send_error(
                    websocket,
                    exc,
                    sequence=error_sequence,
                    node_id=node.id,
                    room_id=node.room_id,
                )
                if exc.code in {"identity_mismatch", "invalid_sequence"}:
                    break
    except (ProtocolValidationError, TimeoutError) as exc:
        if isinstance(exc, TimeoutError):
            error = ProtocolValidationError("hello_timeout", "node.hello was not received in time")
        else:
            error = exc
        await _send_error(websocket, error, sequence=1)
        await websocket.close(code=4003)
    except WebSocketDisconnect:
        pass
    finally:
        if connection is not None and node is not None:
            with CancelScope(shield=True):
                removed = await websocket.app.state.node_registry.disconnect(connection)
                if removed:
                    async with websocket.app.state.session_factory() as session:
                        repository = NodeRepository(session)
                        current = await repository.node_by_id(node.id)
                        if current is not None:
                            await repository.set_status(current, "offline")
                        await AuditRepository(session).add(
                            household_id=node.household_id,
                            actor_type="node",
                            actor_id=node.id,
                            action="node.disconnect",
                            resource_type="node",
                            resource_id=node.id,
                        )
                        await session.commit()
