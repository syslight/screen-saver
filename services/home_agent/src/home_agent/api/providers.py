from __future__ import annotations

import base64
import binascii
from typing import Literal, cast

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, ConfigDict, Field, SecretStr
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.api.dependencies import get_parent, get_session
from home_agent.errors import DomainError
from home_agent.repositories.audit import AuditRepository
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.services.voice_providers import (
    ProviderConfigurationError,
    ProviderFieldValue,
    ProviderNotConfiguredError,
    ProviderSelectionError,
    VoiceProviderRegistry,
    VoiceProviderSelection,
    provider_kind,
)

router = APIRouter(prefix="/api/v1/admin/providers", tags=["admin-providers"])

LegacyCredentialName = Literal[
    "volcanoAppId",
    "volcanoApiKey",
    "volcanoAccessToken",
    "openaiApiKey",
    "glmApiKey",
    "kimiApiKey",
]


class ProviderSelectionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    asr: Literal["volcano", "local", "openai"]
    tts: Literal["volcano", "piper", "openai"]
    llm: Literal["glm", "kimi"]


class ProviderCheckRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: Literal["asr", "tts", "llm"]
    name: str


class ProviderTestRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: Literal["asr", "tts", "llm"]
    name: str
    text: str | None = Field(default=None, max_length=500)
    audio_base64: str | None = Field(default=None, alias="audioBase64", max_length=3_000_000)


class ProviderCredentialsRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    volcano_app_id: str | None = Field(
        default=None, alias="volcanoAppId", min_length=1, max_length=256
    )
    volcano_api_key: SecretStr | None = Field(
        default=None, alias="volcanoApiKey", min_length=1, max_length=8192
    )
    volcano_access_token: SecretStr | None = Field(
        default=None, alias="volcanoAccessToken", min_length=1, max_length=8192
    )
    openai_api_key: SecretStr | None = Field(
        default=None, alias="openaiApiKey", min_length=1, max_length=8192
    )
    glm_api_key: SecretStr | None = Field(
        default=None, alias="glmApiKey", min_length=1, max_length=8192
    )
    kimi_api_key: SecretStr | None = Field(
        default=None, alias="kimiApiKey", min_length=1, max_length=8192
    )
    clear: list[LegacyCredentialName] = Field(default_factory=list, max_length=6)


class ProviderConfigurationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    values: dict[str, ProviderFieldValue] = Field(default_factory=dict, max_length=32)
    clear: list[str] = Field(default_factory=list, max_length=32)


@router.get("")
async def provider_status(
    request: Request, _parent: AuthenticatedParent = Depends(get_parent)
) -> dict[str, object]:
    registry = cast(VoiceProviderRegistry, request.app.state.voice_providers)
    return registry.status()


@router.put("/selection")
async def update_provider_selection(
    body: ProviderSelectionRequest,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    registry = cast(VoiceProviderRegistry, request.app.state.voice_providers)
    previous = registry.selection
    selection = VoiceProviderSelection(asr=body.asr, tts=body.tts, llm=body.llm)
    try:
        await registry.select(selection)
    except ProviderSelectionError as error:
        raise DomainError("invalid_provider_selection", str(error), status_code=422) from error
    await AuditRepository(session).add(
        household_id=parent.user.household_id,
        actor_type="parent",
        actor_id=parent.user.id,
        action="voice.providers.select",
        resource_type="voice_provider_selection",
        payload={"before": previous.__dict__, "after": selection.__dict__},
    )
    await session.commit()
    return registry.status()


@router.post("/check")
async def check_provider(
    body: ProviderCheckRequest,
    request: Request,
    _parent: AuthenticatedParent = Depends(get_parent),
) -> dict[str, object]:
    registry = cast(VoiceProviderRegistry, request.app.state.voice_providers)
    try:
        await registry.check(provider_kind(body.kind), body.name)
    except ProviderNotConfiguredError as error:
        raise DomainError("provider_not_configured", str(error), status_code=409) from error
    except ProviderSelectionError as error:
        raise DomainError("invalid_provider", str(error), status_code=422) from error
    except Exception:
        # 具体供应商响应可能包含敏感信息；后台只读取 registry 中的归一化错误状态。
        pass
    return registry.status()


@router.post("/test")
async def test_provider(
    body: ProviderTestRequest,
    request: Request,
    _parent: AuthenticatedParent = Depends(get_parent),
) -> dict[str, object]:
    registry = cast(VoiceProviderRegistry, request.app.state.voice_providers)
    pcm: bytes | None = None
    if body.audio_base64 is not None:
        try:
            pcm = base64.b64decode(body.audio_base64, validate=True)
        except (ValueError, binascii.Error) as error:
            raise DomainError(
                "invalid_provider_test_audio",
                "ASR test audio must be valid Base64 PCM16",
                status_code=422,
            ) from error
        if len(pcm) > request.app.state.settings.voice_max_audio_bytes:
            raise DomainError(
                "provider_test_audio_too_large",
                "ASR test audio is too large",
                status_code=413,
            )
        if len(pcm) % 2:
            raise DomainError(
                "invalid_provider_test_audio",
                "ASR test audio must contain complete PCM16 samples",
                status_code=422,
            )
    try:
        result = await registry.test(
            provider_kind(body.kind),
            body.name,
            text=body.text,
            pcm=pcm,
        )
    except ProviderNotConfiguredError as error:
        raise DomainError("provider_not_configured", str(error), status_code=409) from error
    except (ProviderSelectionError, ProviderConfigurationError) as error:
        raise DomainError("invalid_provider_test", str(error), status_code=422) from error
    except Exception as error:
        providers = cast(dict[str, list[dict[str, object]]], registry.status()["providers"])
        provider = next(item for item in providers[body.kind] if item["name"] == body.name)
        raise DomainError(
            "provider_test_failed",
            str(provider.get("message") or "Provider test failed"),
            status_code=502,
        ) from error
    response: dict[str, object] = {
        "kind": body.kind,
        "name": body.name,
        "latencyMs": result.latency_ms,
    }
    if result.text is not None:
        response["text"] = result.text
    if result.audio is not None:
        response["audioBase64"] = base64.b64encode(result.audio).decode("ascii")
        response["audioMimeType"] = "audio/wav"
    return response


@router.put("/{kind}/{name}/configuration")
async def update_provider_configuration(
    kind: str,
    name: str,
    body: ProviderConfigurationRequest,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    registry = cast(VoiceProviderRegistry, request.app.state.voice_providers)
    try:
        typed_kind = provider_kind(kind)
        await registry.update_configuration(
            typed_kind,
            name,
            body.values,
            set(body.clear),
        )
    except ProviderConfigurationError as error:
        raise DomainError("invalid_provider_configuration", str(error), status_code=422) from error
    except ProviderSelectionError as error:
        raise DomainError("invalid_provider", str(error), status_code=422) from error
    await AuditRepository(session).add(
        household_id=parent.user.household_id,
        actor_type="parent",
        actor_id=parent.user.id,
        action="voice.provider.configuration.update",
        resource_type="voice_provider_configuration",
        resource_id=f"{typed_kind}.{name}",
        payload={
            "kind": typed_kind,
            "provider": name,
            "updated": sorted(body.values),
            "cleared": sorted(body.clear),
        },
    )
    await session.commit()
    return registry.status()


@router.put("/credentials")
async def update_provider_credentials(
    body: ProviderCredentialsRequest,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    registry = cast(VoiceProviderRegistry, request.app.state.voice_providers)
    dumped = body.model_dump(by_alias=True, exclude_none=True, exclude={"clear"})
    values: dict[str, str] = {}
    for raw_name, raw_value in dumped.items():
        name = str(raw_name)
        values[name] = (
            raw_value.get_secret_value() if isinstance(raw_value, SecretStr) else str(raw_value)
        )
    clear = {str(name) for name in body.clear}
    overlap = clear.intersection(values)
    if overlap:
        raise DomainError(
            "invalid_provider_credentials",
            "A credential cannot be updated and cleared in the same request",
            status_code=422,
            details={"fields": sorted(overlap)},
        )
    await registry.update_credentials(values, clear)
    await AuditRepository(session).add(
        household_id=parent.user.household_id,
        actor_type="parent",
        actor_id=parent.user.id,
        action="voice.providers.credentials.update",
        resource_type="voice_provider_credentials",
        payload={"updated": sorted(values), "cleared": sorted(clear)},
    )
    await session.commit()
    return registry.status()
