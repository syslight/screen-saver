from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.api.dependencies import get_parent, get_session
from home_agent.api.schemas import (
    BootstrapRequest,
    BootstrapResponse,
    CreateParentRequest,
    UserResponse,
)
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.services.auth import AuthService

router = APIRouter(tags=["household"])


@router.post("/api/v1/bootstrap", response_model=BootstrapResponse, status_code=201)
async def bootstrap(
    body: BootstrapRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> BootstrapResponse:
    result = await AuthService(session, request.app.state.settings).bootstrap(
        body.household_name, body.timezone, body.username, body.password
    )
    await session.commit()
    return BootstrapResponse(
        household_id=result.household.id,
        room_id=result.room.id,
        user_id=result.user.id,
    )


@router.post("/api/v1/users", response_model=UserResponse, status_code=201)
async def create_parent(
    body: CreateParentRequest,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> UserResponse:
    service = AuthService(session, request.app.state.settings)
    current = await service.authenticate_parent_ids(parent.session.id, parent.user.id)
    user = await service.create_parent(current, body.username, body.password)
    await session.commit()
    return UserResponse(id=user.id, username=user.username, role=user.role)
