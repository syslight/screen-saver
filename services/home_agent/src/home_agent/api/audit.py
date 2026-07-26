from __future__ import annotations

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.api.dependencies import get_parent, get_session
from home_agent.api.schemas import AuditResponse
from home_agent.repositories.audit import AuditRepository
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.services.auth import AuthService

router = APIRouter(prefix="/api/v1", tags=["audit"])


@router.get("/audit-events", response_model=list[AuditResponse])
async def audit_events(
    request: Request,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> list[AuditResponse]:
    current = await AuthService(session, request.app.state.settings).authenticate_parent_ids(
        parent.session.id, parent.user.id
    )
    events = await AuditRepository(session).list_for_household(
        current.user.household_id, limit=limit, offset=offset
    )
    return [
        AuditResponse(
            id=item.id,
            actor_type=item.actor_type,
            actor_id=item.actor_id,
            action=item.action,
            resource_type=item.resource_type,
            resource_id=item.resource_id,
            reason=item.reason,
            payload=item.payload_json,
            created_at=item.created_at,
        )
        for item in events
    ]
