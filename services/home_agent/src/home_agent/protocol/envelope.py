from __future__ import annotations

from datetime import UTC, datetime
from typing import Any
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from home_agent.protocol.messages import PAYLOAD_TYPES, StrictPayload

PROTOCOL_VERSION = 1


class ProtocolValidationError(ValueError):
    def __init__(self, code: str, message: str, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


class Envelope(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    protocol_version: int = Field(alias="protocolVersion")
    message_id: str = Field(alias="messageId")
    sequence: int = Field(ge=1)
    type: str
    sent_at: datetime = Field(alias="sentAt")
    node_id: str | None = Field(default=None, alias="nodeId")
    room_id: str | None = Field(default=None, alias="roomId")
    session_id: str | None = Field(default=None, alias="sessionId")
    payload: dict[str, Any]

    @field_validator("message_id", "node_id", "room_id", "session_id")
    @classmethod
    def validate_uuid(cls, value: str | None) -> str | None:
        if value is not None:
            UUID(value)
        return value

    def json_dict(self) -> dict[str, Any]:
        return self.model_dump(mode="json", by_alias=True)


class ParsedEnvelope:
    def __init__(self, envelope: Envelope, payload: StrictPayload) -> None:
        self.envelope = envelope
        self.payload = payload


def parse_envelope(data: dict[str, Any]) -> ParsedEnvelope:
    try:
        envelope = Envelope.model_validate(data)
    except ValidationError as exc:
        raise ProtocolValidationError(
            "invalid_envelope", "Message envelope is invalid", {"errors": exc.errors()}
        ) from exc
    if envelope.protocol_version != PROTOCOL_VERSION:
        raise ProtocolValidationError(
            "unsupported_protocol_version",
            f"Protocol version {envelope.protocol_version} is not supported",
            {"supported": [PROTOCOL_VERSION]},
        )
    payload_type = PAYLOAD_TYPES.get(envelope.type)
    if payload_type is None:
        raise ProtocolValidationError("unknown_message_type", f"Unknown type: {envelope.type}")
    try:
        payload = payload_type.model_validate(envelope.payload)
    except ValidationError as exc:
        raise ProtocolValidationError(
            "invalid_payload", "Message payload is invalid", {"errors": exc.errors()}
        ) from exc
    return ParsedEnvelope(envelope, payload)


def make_envelope(
    message_type: str,
    payload: StrictPayload | dict[str, Any],
    *,
    sequence: int,
    node_id: str | None = None,
    room_id: str | None = None,
    session_id: str | None = None,
    message_id: str | None = None,
) -> Envelope:
    payload_data = (
        payload.model_dump(mode="json", by_alias=True)
        if isinstance(payload, BaseModel)
        else payload
    )
    return Envelope(
        protocol_version=PROTOCOL_VERSION,
        message_id=message_id or str(uuid4()),
        sequence=sequence,
        type=message_type,
        sent_at=datetime.now(UTC),
        node_id=node_id,
        room_id=room_id,
        session_id=session_id,
        payload=payload_data,
    )
