from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.api.dependencies import get_parent, get_session
from home_agent.api.schemas import LoginRequest, LoginResponse
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.services.auth import AuthService

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])


@router.post("/login", response_model=LoginResponse)
async def login(
    body: LoginRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> LoginResponse:
    client = request.client.host if request.client else "unknown"
    request.app.state.login_limiter.check(f"{client}:{body.username}")
    service = AuthService(session, request.app.state.settings)
    token, auth_session, user = await service.login(body.username, body.password)
    await session.commit()
    return LoginResponse(
        token=token,
        expires_at=auth_session.expires_at,
        user_id=user.id,
        household_id=user.household_id,
    )


@router.post("/logout", status_code=204)
async def logout(
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> None:
    service = AuthService(session, request.app.state.settings)
    row = await service.authenticate_parent_ids(parent.session.id, parent.user.id)
    await service.logout(row)
    await session.commit()
