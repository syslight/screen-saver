from __future__ import annotations

from collections.abc import Sequence
from datetime import datetime
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.domain.models import Node, NodeCapability, PairingCode, utc_now


class NodeRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def pairing_by_hash(self, code_hash: str) -> PairingCode | None:
        result = await self.session.scalar(
            select(PairingCode).where(PairingCode.code_hash == code_hash)
        )
        return result

    async def node(self, household_id: str, node_id: str) -> Node | None:
        result = await self.session.scalar(
            select(Node).where(Node.household_id == household_id, Node.id == node_id)
        )
        return result

    async def node_by_id(self, node_id: str) -> Node | None:
        result = await self.session.scalar(select(Node).where(Node.id == node_id))
        return result

    async def list_nodes(self, household_id: str) -> list[Node]:
        result = await self.session.scalars(
            select(Node).where(Node.household_id == household_id).order_by(Node.created_at)
        )
        return list(result)

    async def capabilities(self, node_id: str) -> list[NodeCapability]:
        result = await self.session.scalars(
            select(NodeCapability)
            .where(NodeCapability.node_id == node_id)
            .order_by(NodeCapability.capability_id)
        )
        return list(result)

    async def replace_capabilities(
        self, node_id: str, capabilities: Sequence[dict[str, Any]]
    ) -> None:
        await self.session.execute(delete(NodeCapability).where(NodeCapability.node_id == node_id))
        self.session.add_all(
            [
                NodeCapability(
                    node_id=node_id,
                    capability_id=item["capabilityId"],
                    type=item["type"],
                    status=item["status"],
                    properties_json=item.get("properties", {}),
                    commands_json=item.get("commands", []),
                )
                for item in capabilities
            ]
        )
        await self.session.flush()

    async def set_status(self, node: Node, status: str) -> None:
        node.status = status
        node.last_seen_at = utc_now()
        await self.session.flush()

    async def create_pairing(
        self,
        *,
        code_hash: str,
        household_id: str,
        room_id: str,
        expires_at: datetime,
        created_by: str,
    ) -> PairingCode:
        code = PairingCode(
            code_hash=code_hash,
            household_id=household_id,
            room_id=room_id,
            expires_at=expires_at,
            created_by=created_by,
        )
        self.session.add(code)
        await self.session.flush()
        return code

    async def create_node(
        self,
        *,
        household_id: str,
        room_id: str,
        name: str,
        platform: str,
        device_key_hash: str,
    ) -> Node:
        node = Node(
            household_id=household_id,
            room_id=room_id,
            name=name,
            platform=platform,
            device_key_hash=device_key_hash,
        )
        self.session.add(node)
        await self.session.flush()
        return node
