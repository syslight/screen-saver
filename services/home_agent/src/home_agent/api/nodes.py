from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.api.dependencies import get_parent, get_session
from home_agent.api.schemas import (
    CapabilityResponse,
    CommandRequest,
    CommandResponse,
    NodeResponse,
    PairingCodeRequest,
    PairingCodeResponse,
    PairNodeRequest,
    PairNodeResponse,
)
from home_agent.domain.models import Node, NodeCapability
from home_agent.errors import DomainError
from home_agent.repositories.audit import AuditRepository
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.repositories.node import NodeRepository
from home_agent.services.auth import AuthService
from home_agent.services.pairing import PairingService

router = APIRouter(prefix="/api/v1", tags=["nodes"])


async def _current_parent(
    session: AsyncSession, request: Request, parent: AuthenticatedParent
) -> AuthenticatedParent:
    return await AuthService(session, request.app.state.settings).authenticate_parent_ids(
        parent.session.id, parent.user.id
    )


def _node_response(node: Node, capabilities: list[NodeCapability]) -> NodeResponse:
    return NodeResponse(
        id=node.id,
        room_id=node.room_id,
        name=node.name,
        platform=node.platform,
        status=node.status,
        last_seen_at=node.last_seen_at,
        capabilities=[
            CapabilityResponse(
                capability_id=item.capability_id,
                type=item.type,
                status=item.status,
                properties=item.properties_json,
                commands=item.commands_json,
            )
            for item in capabilities
        ],
    )


@router.post("/node-pairing-codes", response_model=PairingCodeResponse, status_code=201)
async def create_pairing_code(
    body: PairingCodeRequest,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> PairingCodeResponse:
    current = await _current_parent(session, request, parent)
    code, pairing = await PairingService(session, request.app.state.settings).create_code(
        current, body.room_id
    )
    await session.commit()
    return PairingCodeResponse(code=code, expires_at=pairing.expires_at)


@router.post("/nodes/pair", response_model=PairNodeResponse, status_code=201)
async def pair_node(
    body: PairNodeRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> PairNodeResponse:
    client = request.client.host if request.client else "unknown"
    request.app.state.pairing_limiter.check(client)
    node, device_key = await PairingService(session, request.app.state.settings).pair(
        body.code, body.name, body.platform
    )
    await session.commit()
    return PairNodeResponse(node_id=node.id, room_id=node.room_id, device_key=device_key)


@router.get("/nodes", response_model=list[NodeResponse])
async def list_nodes(
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> list[NodeResponse]:
    current = await _current_parent(session, request, parent)
    repository = NodeRepository(session)
    result = []
    for node in await repository.list_nodes(current.user.household_id):
        capabilities = await repository.capabilities(node.id)
        result.append(_node_response(node, list(capabilities)))
    return result


@router.get("/nodes/{node_id}", response_model=NodeResponse)
async def get_node(
    node_id: str,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> NodeResponse:
    current = await _current_parent(session, request, parent)
    repository = NodeRepository(session)
    node = await repository.node(current.user.household_id, node_id)
    if node is None:
        raise DomainError("node_not_found", "Node was not found", status_code=404)
    return _node_response(node, list(await repository.capabilities(node.id)))


@router.post("/nodes/{node_id}/commands", response_model=CommandResponse)
async def send_command(
    node_id: str,
    body: CommandRequest,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> CommandResponse:
    current = await _current_parent(session, request, parent)
    repository = NodeRepository(session)
    node = await repository.node(current.user.household_id, node_id)
    if node is None:
        raise DomainError("node_not_found", "Node was not found", status_code=404)
    result = await request.app.state.node_registry.send_command(
        node.id,
        node.room_id,
        body.command_name,
        body.arguments,
        timeout_seconds=request.app.state.settings.command_timeout_seconds,
    )
    await AuditRepository(session).add(
        household_id=current.user.household_id,
        actor_type="user",
        actor_id=current.user.id,
        action="node.command",
        resource_type="node",
        resource_id=node.id,
        payload={"commandName": body.command_name, "success": result.success},
    )
    await session.commit()
    return CommandResponse(
        success=result.success, result=result.result, error_code=result.error_code
    )
