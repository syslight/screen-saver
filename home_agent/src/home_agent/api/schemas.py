from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class ApiModel(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True, populate_by_name=True)


class BootstrapRequest(ApiModel):
    household_name: str = Field(alias="householdName", min_length=1, max_length=120)
    timezone: str = Field(default="Asia/Shanghai", min_length=1, max_length=64)
    username: str = Field(min_length=2, max_length=80)
    password: str = Field(min_length=10, max_length=256)


class BootstrapResponse(ApiModel):
    household_id: str = Field(alias="householdId")
    room_id: str = Field(alias="roomId")
    user_id: str = Field(alias="userId")


class LoginRequest(ApiModel):
    username: str
    password: str


class LoginResponse(ApiModel):
    token: str
    expires_at: datetime = Field(alias="expiresAt")
    user_id: str = Field(alias="userId")
    household_id: str = Field(alias="householdId")


class CreateParentRequest(ApiModel):
    username: str = Field(min_length=2, max_length=80)
    password: str = Field(min_length=10, max_length=256)


class UserResponse(ApiModel):
    id: str
    username: str
    role: str


class PairingCodeRequest(ApiModel):
    room_id: str = Field(alias="roomId")


class PairingCodeResponse(ApiModel):
    code: str
    expires_at: datetime = Field(alias="expiresAt")


class PairNodeRequest(ApiModel):
    code: str
    name: str = Field(min_length=1, max_length=120)
    platform: str = Field(min_length=1, max_length=40)


class PairNodeResponse(ApiModel):
    node_id: str = Field(alias="nodeId")
    room_id: str = Field(alias="roomId")
    device_key: str = Field(alias="deviceKey")


class CapabilityResponse(ApiModel):
    capability_id: str = Field(alias="capabilityId")
    type: str
    status: str
    properties: dict[str, Any]
    commands: list[str]


class NodeResponse(ApiModel):
    id: str
    room_id: str = Field(alias="roomId")
    name: str
    platform: str
    status: str
    last_seen_at: datetime | None = Field(alias="lastSeenAt")
    capabilities: list[CapabilityResponse] = Field(default_factory=list)


class CommandRequest(ApiModel):
    command_name: str = Field(alias="commandName", min_length=1)
    arguments: dict[str, Any] = Field(default_factory=dict)


class CommandResponse(ApiModel):
    success: bool
    result: dict[str, Any]
    error_code: str | None = Field(alias="errorCode")


class AuditResponse(ApiModel):
    id: str
    actor_type: str = Field(alias="actorType")
    actor_id: str | None = Field(alias="actorId")
    action: str
    resource_type: str | None = Field(alias="resourceType")
    resource_id: str | None = Field(alias="resourceId")
    reason: str | None
    payload: dict[str, Any]
    created_at: datetime = Field(alias="createdAt")
