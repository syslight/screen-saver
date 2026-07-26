from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Any

from fastapi import WebSocket

from home_agent.errors import DomainError
from home_agent.protocol.envelope import Envelope, make_envelope
from home_agent.protocol.messages import CommandRequestPayload, CommandResultPayload


@dataclass
class NodeConnection:
    node_id: str
    room_id: str
    websocket: WebSocket
    outgoing_sequence: int = 0
    pending: dict[str, asyncio.Future[CommandResultPayload]] = field(default_factory=dict)
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def send(self, envelope: Envelope) -> None:
        async with self.send_lock:
            await self.websocket.send_json(envelope.json_dict())

    def next_sequence(self) -> int:
        self.outgoing_sequence += 1
        return self.outgoing_sequence


class NodeRegistry:
    def __init__(self) -> None:
        self._connections: dict[str, NodeConnection] = {}
        self._lock = asyncio.Lock()

    async def connect(self, connection: NodeConnection) -> NodeConnection | None:
        async with self._lock:
            previous = self._connections.get(connection.node_id)
            self._connections[connection.node_id] = connection
        if previous is not None:
            await previous.websocket.close(code=4001, reason="Replaced by a newer connection")
            for future in previous.pending.values():
                if not future.done():
                    future.set_exception(DomainError("node_reconnected", "Node reconnected"))
        return previous

    async def disconnect(self, connection: NodeConnection) -> bool:
        async with self._lock:
            if self._connections.get(connection.node_id) is not connection:
                return False
            del self._connections[connection.node_id]
        for future in connection.pending.values():
            if not future.done():
                future.set_exception(DomainError("node_disconnected", "Node disconnected"))
        return True

    def is_online(self, node_id: str) -> bool:
        return node_id in self._connections

    def resolve_result(self, node_id: str, result: CommandResultPayload) -> bool:
        connection = self._connections.get(node_id)
        if connection is None:
            return False
        future = connection.pending.get(result.request_message_id)
        if future is None or future.done():
            return False
        future.set_result(result)
        return True

    async def send_command(
        self,
        node_id: str,
        room_id: str,
        command_name: str,
        arguments: dict[str, Any],
        *,
        timeout_seconds: float,
    ) -> CommandResultPayload:
        connection = self._connections.get(node_id)
        if connection is None:
            raise DomainError("node_offline", "Node is offline", status_code=409)
        envelope = make_envelope(
            "command.request",
            CommandRequestPayload(command_name=command_name, arguments=arguments),
            sequence=connection.next_sequence(),
            node_id=node_id,
            room_id=room_id,
        )
        future: asyncio.Future[CommandResultPayload] = asyncio.get_running_loop().create_future()
        connection.pending[envelope.message_id] = future
        try:
            await connection.send(envelope)
            return await asyncio.wait_for(future, timeout=timeout_seconds)
        except TimeoutError as exc:
            raise DomainError("command_timeout", "Node command timed out", status_code=504) from exc
        finally:
            connection.pending.pop(envelope.message_id, None)
