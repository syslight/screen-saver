from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import update
from sqlalchemy.engine import CursorResult
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.config import Settings
from home_agent.domain.models import Node, PairingCode, utc_now
from home_agent.errors import DomainError
from home_agent.repositories.audit import AuditRepository
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.repositories.household import HouseholdRepository
from home_agent.repositories.node import NodeRepository
from home_agent.security import credential_hash, random_credential


def _utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value


class PairingService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.nodes = NodeRepository(session)
        self.households = HouseholdRepository(session)
        self.audit = AuditRepository(session)

    async def create_code(
        self, parent: AuthenticatedParent, room_id: str
    ) -> tuple[str, PairingCode]:
        room = await self.households.room(parent.user.household_id, room_id)
        if room is None:
            raise DomainError("room_not_found", "Room was not found", status_code=404)
        code = random_credential(12)
        pairing = await self.nodes.create_pairing(
            code_hash=credential_hash(code),
            household_id=parent.user.household_id,
            room_id=room.id,
            expires_at=utc_now() + timedelta(seconds=self.settings.pairing_ttl_seconds),
            created_by=parent.user.id,
        )
        await self.audit.add(
            household_id=parent.user.household_id,
            actor_type="user",
            actor_id=parent.user.id,
            action="node.pairing_code.create",
            resource_type="room",
            resource_id=room.id,
        )
        return code, pairing

    async def pair(self, code: str, name: str, platform: str) -> tuple[Node, str]:
        pairing = await self.nodes.pairing_by_hash(credential_hash(code))
        if pairing is None:
            raise DomainError("invalid_pairing_code", "Pairing code is invalid", status_code=401)
        now = utc_now()
        if pairing.used_at is not None:
            raise DomainError(
                "pairing_code_used", "Pairing code has already been used", status_code=409
            )
        if _utc(pairing.expires_at) <= now:
            raise DomainError("pairing_code_expired", "Pairing code has expired", status_code=410)
        consumed = await self.session.execute(
            update(PairingCode)
            .where(
                PairingCode.id == pairing.id,
                PairingCode.used_at.is_(None),
                PairingCode.expires_at > now,
            )
            .values(used_at=now),
            execution_options={"synchronize_session": False},
        )
        if not isinstance(consumed, CursorResult) or consumed.rowcount != 1:
            raise DomainError(
                "pairing_code_used", "Pairing code has already been used", status_code=409
            )
        device_key = random_credential()
        node = await self.nodes.create_node(
            household_id=pairing.household_id,
            room_id=pairing.room_id,
            name=name,
            platform=platform,
            device_key_hash=credential_hash(device_key),
        )
        await self.audit.add(
            household_id=pairing.household_id,
            actor_type="node",
            actor_id=node.id,
            action="node.pair",
            resource_type="node",
            resource_id=node.id,
            payload={"platform": platform, "roomId": pairing.room_id},
        )
        await self.session.flush()
        return node, device_key
