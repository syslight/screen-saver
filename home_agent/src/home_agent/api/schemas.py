from __future__ import annotations

from datetime import date, datetime
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


class MemberCreate(ApiModel):
    display_name: str = Field(alias="displayName", min_length=1, max_length=80)
    role: str
    age: int | None = Field(default=None, ge=0, le=120)


class MemberUpdate(ApiModel):
    display_name: str | None = Field(default=None, alias="displayName", min_length=1, max_length=80)
    age: int | None = Field(default=None, ge=0, le=120)
    active: bool | None = None


class MemberResponse(ApiModel):
    id: str
    display_name: str = Field(alias="displayName")
    role: str
    age: int | None
    active: bool


class HomeworkTaskCreate(ApiModel):
    child_id: str = Field(alias="childId")
    title: str = Field(min_length=1, max_length=160)
    subject: str = Field(default="math", min_length=1, max_length=40)
    task_date: date = Field(alias="taskDate")
    due_at: datetime | None = Field(default=None, alias="dueAt")
    instructions: str = Field(min_length=1, max_length=10_000)
    reference_answer: str | None = Field(default=None, alias="referenceAnswer", max_length=20_000)
    rubric: str | None = Field(default=None, max_length=10_000)


class HomeworkTaskUpdate(ApiModel):
    title: str | None = Field(default=None, min_length=1, max_length=160)
    subject: str | None = Field(default=None, min_length=1, max_length=40)
    task_date: date | None = Field(default=None, alias="taskDate")
    due_at: datetime | None = Field(default=None, alias="dueAt")
    instructions: str | None = Field(default=None, min_length=1, max_length=10_000)
    reference_answer: str | None = Field(default=None, alias="referenceAnswer", max_length=20_000)
    rubric: str | None = Field(default=None, max_length=10_000)


class HomeworkTaskResponse(ApiModel):
    id: str
    child_id: str = Field(alias="childId")
    title: str
    subject: str
    task_date: date = Field(alias="taskDate")
    due_at: datetime | None = Field(alias="dueAt")
    instructions: str
    reference_answer: str | None = Field(alias="referenceAnswer")
    rubric: str | None
    status: str
    created_at: datetime = Field(alias="createdAt")
    updated_at: datetime = Field(alias="updatedAt")


class HomeworkAssetResponse(ApiModel):
    id: str
    media_type: str = Field(alias="mediaType")
    size_bytes: int = Field(alias="sizeBytes")
    sha256: str
    url: str


class HomeworkReviewResponse(ApiModel):
    id: str
    decision: str
    summary: str
    quality_level: str = Field(alias="qualityLevel")
    items: list[dict[str, Any]]
    created_at: datetime = Field(alias="createdAt")


class HomeworkSubmissionResponse(ApiModel):
    id: str
    task_id: str = Field(alias="taskId")
    attempt_no: int = Field(alias="attemptNo")
    status: str
    submitted_at: datetime = Field(alias="submittedAt")
    assets: list[HomeworkAssetResponse]
    reviews: list[HomeworkReviewResponse]


class HomeworkReviewRequest(ApiModel):
    decision: str
    summary: str = Field(min_length=1, max_length=10_000)
    quality_level: str = Field(alias="qualityLevel")
    items: list[dict[str, Any]] = Field(default_factory=list, max_length=200)


class HomeworkEventResponse(ApiModel):
    id: str
    task_id: str = Field(alias="taskId")
    submission_id: str | None = Field(alias="submissionId")
    actor_type: str = Field(alias="actorType")
    actor_id: str | None = Field(alias="actorId")
    event_type: str = Field(alias="eventType")
    payload: dict[str, Any]
    created_at: datetime = Field(alias="createdAt")


class StudentPairingCodeRequest(ApiModel):
    child_id: str = Field(alias="childId")


class StudentPairingCodeResponse(ApiModel):
    code: str
    child_id: str = Field(alias="childId")
    child_name: str = Field(alias="childName")
    expires_at: datetime = Field(alias="expiresAt")


class PairStudentDeviceRequest(ApiModel):
    code: str = Field(min_length=1, max_length=256)
    name: str = Field(min_length=1, max_length=120)
    platform: str = Field(default="android", min_length=1, max_length=40)


class PairStudentDeviceResponse(ApiModel):
    device_id: str = Field(alias="deviceId")
    device_key: str = Field(alias="deviceKey")
    child_id: str = Field(alias="childId")
    child_name: str = Field(alias="childName")


class StudentDeviceResponse(ApiModel):
    id: str
    child_id: str = Field(alias="childId")
    child_name: str = Field(alias="childName")
    name: str
    platform: str
    active: bool
    last_seen_at: datetime | None = Field(alias="lastSeenAt")
    created_at: datetime = Field(alias="createdAt")


class StudentMeResponse(ApiModel):
    device_id: str = Field(alias="deviceId")
    device_name: str = Field(alias="deviceName")
    child_id: str = Field(alias="childId")
    child_name: str = Field(alias="childName")


class StudentHomeworkTaskResponse(ApiModel):
    id: str
    title: str
    subject: str
    task_date: date = Field(alias="taskDate")
    due_at: datetime | None = Field(alias="dueAt")
    instructions: str
    status: str
    created_at: datetime = Field(alias="createdAt")
    updated_at: datetime = Field(alias="updatedAt")


class StudentHomeworkReviewResponse(ApiModel):
    decision: str
    summary: str
    quality_level: str = Field(alias="qualityLevel")
    created_at: datetime = Field(alias="createdAt")


class StudentHomeworkSubmissionResponse(ApiModel):
    id: str
    task_id: str = Field(alias="taskId")
    attempt_no: int = Field(alias="attemptNo")
    status: str
    submitted_at: datetime = Field(alias="submittedAt")
    asset_count: int = Field(alias="assetCount")
    reviews: list[StudentHomeworkReviewResponse]
