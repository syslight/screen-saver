from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.domain.models import AuditEvent


class AuditRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def add(
        self,
        *,
        household_id: str | None,
        actor_type: str,
        actor_id: str | None,
        action: str,
        resource_type: str | None = None,
        resource_id: str | None = None,
        reason: str | None = None,
        payload: dict[str, Any] | None = None,
    ) -> AuditEvent:
        event = AuditEvent(
            household_id=household_id,
            actor_type=actor_type,
            actor_id=actor_id,
            action=action,
            resource_type=resource_type,
            resource_id=resource_id,
            reason=reason,
            payload_json=payload or {},
        )
        self.session.add(event)
        await self.session.flush()
        return event

    async def list_for_household(
        self, household_id: str, *, limit: int, offset: int
    ) -> list[AuditEvent]:
        result = await self.session.scalars(
            select(AuditEvent)
            .where(AuditEvent.household_id == household_id)
            .order_by(AuditEvent.created_at.desc())
            .limit(limit)
            .offset(offset)
        )
        return list(result)
