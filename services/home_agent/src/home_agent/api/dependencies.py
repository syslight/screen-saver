from __future__ import annotations

import secrets
from collections.abc import AsyncIterator

from fastapi import Header, Request
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.domain.models import Node
from home_agent.errors import DomainError
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.repositories.node import NodeRepository
from home_agent.repositories.student import StudentPrincipal
from home_agent.security import credential_hash
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


async def get_node_device(
    request: Request,
    authorization: str | None = Header(default=None),
) -> Node:
    if authorization is None or not authorization.startswith("Node "):
        raise DomainError("invalid_node_device", "Node authentication is required", status_code=401)
    credential = authorization.removeprefix("Node ").strip()
    node_id, separator, device_key = credential.partition(":")
    if not separator or not node_id or not device_key:
        raise DomainError("invalid_node_device", "Node credential is invalid", status_code=401)
    async with request.app.state.session_factory() as session:
        node = await NodeRepository(session).node_by_id(node_id)
        if (
            node is None
            or not node.active
            or not secrets.compare_digest(node.device_key_hash, credential_hash(device_key))
        ):
            raise DomainError("invalid_node_device", "Node authentication failed", status_code=401)
        return node
