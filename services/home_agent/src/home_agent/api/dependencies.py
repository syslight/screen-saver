from __future__ import annotations

from collections.abc import AsyncIterator

from fastapi import Header, Request
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.errors import DomainError
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.repositories.student import StudentPrincipal
from home_agent.services.auth import AuthService
from home_agent.services.student import StudentService


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


async def get_student(
    request: Request,
    authorization: str | None = Header(default=None),
) -> StudentPrincipal:
    if authorization is None or not authorization.startswith("Student "):
        raise DomainError(
            "invalid_student_device", "Student device authentication is required", status_code=401
        )
    device_key = authorization.removeprefix("Student ").strip()
    async with request.app.state.session_factory() as session:
        principal = await StudentService(session, request.app.state.settings).authenticate(
            device_key
        )
        await session.commit()
        return principal
