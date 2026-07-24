from __future__ import annotations

from collections.abc import AsyncIterator

from fastapi import Header, Request
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.errors import DomainError
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.services.auth import AuthService


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    async with request.app.state.session_factory() as session:
        yield session


async def get_parent(
    request: Request,
    authorization: str | None = Header(default=None),
) -> AuthenticatedParent:
    if authorization is None or not authorization.startswith("Bearer "):
        raise DomainError("invalid_session", "Authentication is required", status_code=401)
    token = authorization.removeprefix("Bearer ").strip()
    async with request.app.state.session_factory() as session:
        return await AuthService(session, request.app.state.settings).authenticate(token)
