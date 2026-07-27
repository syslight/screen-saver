from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


class StrictPayload(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


class HelloPayload(StrictPayload):
    device_key: str = Field(alias="deviceKey", min_length=20)
    software_version: str = Field(alias="softwareVersion", min_length=1)
    platform: str = Field(min_length=1)
    media_protocol_version: int = Field(alias="mediaProtocolVersion", ge=0)


class Capability(StrictPayload):
    capability_id: str = Field(alias="capabilityId", min_length=1)
    type: str = Field(min_length=1)
    status: Literal["online", "busy", "disabled", "error"]
    properties: dict[str, Any] = Field(default_factory=dict)
    commands: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_known_properties(self) -> Capability:
        expected: dict[str, dict[str, type]] = {
            "camera": {"supportsStill": bool},
            "microphone_array": {"channels": int},
            "speaker": {"volumeControl": bool},
            "display": {"touch": bool},
        }
        for key, value_type in expected.get(self.type, {}).items():
            if key in self.properties and not isinstance(self.properties[key], value_type):
                raise ValueError(f"{self.type}.properties.{key} must be {value_type.__name__}")
        return self


class CapabilitiesPayload(StrictPayload):
    capabilities: list[Capability]


class HeartbeatPayload(StrictPayload):
    nonce: str = Field(min_length=1)


class CommandRequestPayload(StrictPayload):
    command_name: str = Field(alias="commandName", min_length=1)
    arguments: dict[str, Any] = Field(default_factory=dict)


class CommandResultPayload(StrictPayload):
    request_message_id: str = Field(alias="requestMessageId")
    success: bool
    result: dict[str, Any] = Field(default_factory=dict)
    error_code: str | None = Field(default=None, alias="errorCode")


class NodeEventPayload(StrictPayload):
    event_name: str = Field(alias="eventName", min_length=1)
    data: dict[str, Any] = Field(default_factory=dict)


class VoiceTurnStartPayload(StrictPayload):
    turn_id: str = Field(alias="turnId", min_length=8, max_length=80)
    encoding: Literal["pcm_s16le"] = "pcm_s16le"
    sample_rate: Literal[16000] = Field(default=16000, alias="sampleRate")
    channels: Literal[1] = 1


class VoiceTurnStopPayload(StrictPayload):
    turn_id: str = Field(alias="turnId", min_length=8, max_length=80)
    cancelled: bool = False


class VoiceTurnStatePayload(StrictPayload):
    turn_id: str = Field(alias="turnId", min_length=8, max_length=80)
    state: Literal["listening", "processing", "speaking", "idle", "error"]
    target_node_id: str = Field(alias="targetNodeId", min_length=1)
    transcript: str = ""
    reply: str = ""
    continue_dialog: bool = Field(default=True, alias="continueDialog")


class AudioPlayPayload(StrictPayload):
    turn_id: str = Field(alias="turnId", min_length=8, max_length=80)
    media_type: Literal["audio/wav"] = Field(default="audio/wav", alias="mediaType")
    byte_length: int = Field(alias="byteLength", ge=0)


class AudioStreamStartPayload(StrictPayload):
    turn_id: str = Field(alias="turnId", min_length=8, max_length=80)
    media_type: Literal["audio/pcm"] = Field(default="audio/pcm", alias="mediaType")
    encoding: Literal["pcm_s16le"] = "pcm_s16le"
    sample_rate: int = Field(alias="sampleRate", ge=8000, le=48000)
    channels: Literal[1] = 1


class AudioStreamEndPayload(StrictPayload):
    turn_id: str = Field(alias="turnId", min_length=8, max_length=80)
    byte_length: int = Field(alias="byteLength", ge=0)


class ErrorPayload(StrictPayload):
    code: str
    message: str
    details: dict[str, Any] = Field(default_factory=dict)


PAYLOAD_TYPES: dict[str, type[StrictPayload]] = {
    "node.hello": HelloPayload,
    "node.capabilities": CapabilitiesPayload,
    "heartbeat.ping": HeartbeatPayload,
    "heartbeat.pong": HeartbeatPayload,
    "command.request": CommandRequestPayload,
    "command.result": CommandResultPayload,
    "node.event": NodeEventPayload,
    "voice.turn.start": VoiceTurnStartPayload,
    "voice.turn.stop": VoiceTurnStopPayload,
    "voice.turn.state": VoiceTurnStatePayload,
    "audio.play": AudioPlayPayload,
    "audio.stream.start": AudioStreamStartPayload,
    "audio.stream.end": AudioStreamEndPayload,
    "error": ErrorPayload,
}
