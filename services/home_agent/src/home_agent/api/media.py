from __future__ import annotations

import asyncio
import json
from collections.abc import Awaitable, Callable

import httpx
from fastapi import APIRouter, Depends, Query, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse

from home_agent.api.dependencies import get_node_device
from home_agent.api.websocket import _authenticate_hello
from home_agent.domain.models import Node
from home_agent.protocol.envelope import make_envelope, parse_envelope
from home_agent.protocol.messages import (
    AudioPlayPayload,
    AudioStreamEndPayload,
    AudioStreamStartPayload,
    VoiceTurnStartPayload,
    VoiceTurnStatePayload,
    VoiceTurnStopPayload,
)
from home_agent.services.local_speech import StreamingSpeechRecognitionSession
from home_agent.services.media_library import MediaContent
from home_agent.services.voice_agent import (
    VoiceAgentResult,
    VoiceAudioChunkEvent,
    VoiceAudioStartEvent,
    VoiceTranscriptEvent,
)
from home_agent.services.voice_endpoint import VoiceEndpointDetector, VoiceEndpointEvent

router = APIRouter(prefix="/api/v1/media", tags=["media"])


def _content_response(content: MediaContent) -> Response:
    headers = {"ETag": content.etag, "Cache-Control": "private, max-age=86400"}
    if content.path is not None:
        return FileResponse(content.path, media_type=content.media_type, headers=headers)
    return Response(content.data or b"", media_type=content.media_type, headers=headers)


@router.get("/status")
async def media_status(
    request: Request, _node: Node = Depends(get_node_device)
) -> dict[str, object]:
    return await asyncio.to_thread(request.app.state.media_library.status)


@router.get("/photos")
async def photos(
    request: Request,
    _node: Node = Depends(get_node_device),
    limit: int = Query(default=1000, ge=1, le=5000),
    offset: int = Query(default=0, ge=0),
) -> dict[str, object]:
    return await asyncio.to_thread(
        request.app.state.media_library.list_photos, limit=limit, offset=offset
    )


@router.get("/photos/{photo_id}/content")
async def photo_content(
    photo_id: str, request: Request, _node: Node = Depends(get_node_device)
) -> Response:
    content = await request.app.state.media_library.photo_content(photo_id)
    return _content_response(content)


@router.get("/photos/{photo_id}/description")
async def photo_description(
    photo_id: str, request: Request, _node: Node = Depends(get_node_device)
) -> dict[str, object]:
    return await asyncio.to_thread(request.app.state.media_library.describe_photo, photo_id)


@router.get("/music/select", response_model=None)
async def select_music(
    request: Request,
    _node: Node = Depends(get_node_device),
    photo_id: str | None = Query(default=None, alias="photoId"),
    mood: str | None = None,
) -> Response | dict[str, object]:
    selected = await asyncio.to_thread(
        request.app.state.media_library.select_music,
        photo_id=photo_id,
        requested_mood=mood,
    )
    return Response(status_code=204) if selected is None else selected


@router.get("/music/tracks/{track_id}/content")
async def music_content(
    track_id: str, request: Request, _node: Node = Depends(get_node_device)
) -> Response:
    content = await asyncio.to_thread(request.app.state.media_library.music_content, track_id)
    return _content_response(content)


async def _send_state(
    websocket: WebSocket,
    *,
    sequence: int,
    node: Node,
    turn_id: str,
    state: str,
    transcript: str = "",
    reply: str = "",
    continue_dialog: bool = True,
) -> None:
    payload = VoiceTurnStatePayload(
        turn_id=turn_id,
        state=state,
        target_node_id=node.id,
        transcript=transcript,
        reply=reply,
        continue_dialog=continue_dialog,
    )
    await websocket.send_json(
        make_envelope(
            "voice.turn.state",
            payload,
            sequence=sequence,
            node_id=node.id,
            room_id=node.room_id,
        ).json_dict()
    )


async def _process_voice_turn(
    websocket: WebSocket,
    *,
    sequence: int,
    node: Node,
    turn_id: str,
    audio: bytes,
    asr_stream: StreamingSpeechRecognitionSession | None = None,
    media_protocol_version: int = 1,
) -> int:
    process_stream = getattr(websocket.app.state.voice_agent, "process_stream", None)
    if media_protocol_version >= 2 and callable(process_stream):
        return await _process_voice_turn_stream(
            websocket,
            sequence=sequence,
            node=node,
            turn_id=turn_id,
            audio=audio,
            process_stream=process_stream,
            asr_stream=asr_stream,
        )
    sequence += 1
    await _send_state(
        websocket,
        sequence=sequence,
        node=node,
        turn_id=turn_id,
        state="processing",
    )
    try:
        if asr_stream is None:
            result = await websocket.app.state.voice_agent.process(
                audio, node_id=node.id, turn_id=turn_id
            )
        else:
            result = await websocket.app.state.voice_agent.process(
                audio,
                node_id=node.id,
                turn_id=turn_id,
                asr_stream=asr_stream,
            )
    except (httpx.HTTPError, OSError, RuntimeError, ValueError):
        sequence += 1
        await _send_state(
            websocket,
            sequence=sequence,
            node=node,
            turn_id=turn_id,
            state="error",
            reply="语音服务暂时不可用。",
        )
        return sequence

    sequence += 1
    await _send_state(
        websocket,
        sequence=sequence,
        node=node,
        turn_id=turn_id,
        state="speaking",
        transcript=result.transcript,
        reply=result.reply,
        continue_dialog=result.continue_dialog,
    )
    if result.audio:
        sequence += 1
        play = AudioPlayPayload(turn_id=turn_id, byte_length=len(result.audio))
        await websocket.send_json(
            make_envelope(
                "audio.play",
                play,
                sequence=sequence,
                node_id=node.id,
                room_id=node.room_id,
            ).json_dict()
        )
        await websocket.send_bytes(result.audio)
    sequence += 1
    await _send_state(
        websocket,
        sequence=sequence,
        node=node,
        turn_id=turn_id,
        state="idle",
        transcript=result.transcript,
        reply=result.reply,
        continue_dialog=result.continue_dialog,
    )
    return sequence


async def _process_voice_turn_stream(
    websocket: WebSocket,
    *,
    sequence: int,
    node: Node,
    turn_id: str,
    audio: bytes,
    process_stream: Callable[..., Awaitable[VoiceAgentResult]],
    asr_stream: StreamingSpeechRecognitionSession | None,
) -> int:
    sequence += 1
    await _send_state(
        websocket,
        sequence=sequence,
        node=node,
        turn_id=turn_id,
        state="processing",
    )
    transcript = ""
    stream_started = False
    sent_bytes = 0
    pending = bytearray()
    target_chunk_bytes = websocket.app.state.settings.voice_tts_stream_chunk_bytes

    async def send_pending(*, force: bool = False) -> None:
        nonlocal sent_bytes
        while len(pending) >= target_chunk_bytes or (force and pending):
            size = target_chunk_bytes if len(pending) >= target_chunk_bytes else len(pending)
            chunk = bytes(pending[:size])
            del pending[:size]
            await websocket.send_bytes(chunk)
            sent_bytes += len(chunk)

    async def emit(event: object) -> None:
        nonlocal sequence, stream_started, transcript
        if isinstance(event, VoiceTranscriptEvent):
            transcript = event.transcript
            sequence += 1
            await _send_state(
                websocket,
                sequence=sequence,
                node=node,
                turn_id=turn_id,
                state="processing",
                transcript=transcript,
            )
            return
        if isinstance(event, VoiceAudioStartEvent):
            stream_started = True
            sequence += 1
            await _send_state(
                websocket,
                sequence=sequence,
                node=node,
                turn_id=turn_id,
                state="speaking",
                transcript=transcript,
                reply=event.reply_prefix,
            )
            sequence += 1
            payload = AudioStreamStartPayload(
                turn_id=turn_id,
                sample_rate=event.sample_rate,
                channels=event.channels,
            )
            await websocket.send_json(
                make_envelope(
                    "audio.stream.start",
                    payload,
                    sequence=sequence,
                    node_id=node.id,
                    room_id=node.room_id,
                ).json_dict()
            )
            return
        if isinstance(event, VoiceAudioChunkEvent):
            pending.extend(event.data)
            await send_pending()

    try:
        result = await process_stream(
            audio,
            node_id=node.id,
            turn_id=turn_id,
            emit=emit,
            asr_stream=asr_stream,
        )
        await send_pending(force=True)
    except (httpx.HTTPError, OSError, RuntimeError, ValueError):
        if stream_started:
            await send_pending(force=True)
            sequence += 1
            await _send_audio_stream_end(
                websocket,
                sequence=sequence,
                node=node,
                turn_id=turn_id,
                byte_length=sent_bytes,
            )
        sequence += 1
        await _send_state(
            websocket,
            sequence=sequence,
            node=node,
            turn_id=turn_id,
            state="error",
            transcript=transcript,
            reply="语音服务暂时不可用。",
            continue_dialog=False,
        )
        return sequence

    if stream_started:
        sequence += 1
        await _send_audio_stream_end(
            websocket,
            sequence=sequence,
            node=node,
            turn_id=turn_id,
            byte_length=sent_bytes,
        )
    else:
        sequence += 1
        await _send_state(
            websocket,
            sequence=sequence,
            node=node,
            turn_id=turn_id,
            state="speaking",
            transcript=result.transcript,
            reply=result.reply,
            continue_dialog=result.continue_dialog,
        )
    sequence += 1
    await _send_state(
        websocket,
        sequence=sequence,
        node=node,
        turn_id=turn_id,
        state="idle",
        transcript=result.transcript,
        reply=result.reply,
        continue_dialog=result.continue_dialog,
    )
    return sequence


async def _send_audio_stream_end(
    websocket: WebSocket,
    *,
    sequence: int,
    node: Node,
    turn_id: str,
    byte_length: int,
) -> None:
    payload = AudioStreamEndPayload(turn_id=turn_id, byte_length=byte_length)
    await websocket.send_json(
        make_envelope(
            "audio.stream.end",
            payload,
            sequence=sequence,
            node_id=node.id,
            room_id=node.room_id,
        ).json_dict()
    )


@router.websocket("/voice/ws")
async def voice_websocket(websocket: WebSocket) -> None:
    await websocket.accept()
    try:
        _hello, hello_payload, node = await _authenticate_hello(websocket)
    except Exception:
        await websocket.close(code=4003, reason="Node authentication failed")
        return
    sequence = 0
    active_turn: str | None = None
    asr_stream: StreamingSpeechRecognitionSession | None = None
    audio = bytearray()
    endpoint = VoiceEndpointDetector()
    try:
        while True:
            message = await websocket.receive()
            if message["type"] == "websocket.disconnect":
                break
            raw_bytes = message.get("bytes")
            if raw_bytes is not None:
                if active_turn is not None:
                    audio.extend(raw_bytes)
                    if asr_stream is not None:
                        try:
                            await asr_stream.send_audio(raw_bytes)
                        except Exception:
                            await asr_stream.abort()
                            asr_stream = None
                    endpoint_event = endpoint.process(raw_bytes)
                    if len(audio) > websocket.app.state.settings.voice_max_audio_bytes:
                        sequence += 1
                        await _send_state(
                            websocket,
                            sequence=sequence,
                            node=node,
                            turn_id=active_turn,
                            state="error",
                            reply="录音超过大小限制。",
                        )
                        active_turn = None
                        audio.clear()
                        if asr_stream is not None:
                            await asr_stream.abort()
                            asr_stream = None
                    elif endpoint_event is VoiceEndpointEvent.NO_SPEECH_TIMEOUT:
                        turn_id = active_turn
                        active_turn = None
                        audio.clear()
                        if asr_stream is not None:
                            await asr_stream.abort()
                            asr_stream = None
                        sequence += 1
                        await _send_state(
                            websocket,
                            sequence=sequence,
                            node=node,
                            turn_id=turn_id,
                            state="idle",
                            continue_dialog=False,
                        )
                    elif endpoint_event in {
                        VoiceEndpointEvent.ENDPOINT,
                        VoiceEndpointEvent.MAXIMUM_DURATION,
                    }:
                        turn_id = active_turn
                        active_turn = None
                        captured = bytes(audio)
                        audio.clear()
                        completed_stream = asr_stream
                        asr_stream = None
                        sequence = await _process_voice_turn(
                            websocket,
                            sequence=sequence,
                            node=node,
                            turn_id=turn_id,
                            audio=captured,
                            asr_stream=completed_stream,
                            media_protocol_version=hello_payload.media_protocol_version,
                        )
                continue
            raw_text = message.get("text")
            if raw_text is None:
                continue
            parsed = parse_envelope(json.loads(raw_text))
            if parsed.envelope.node_id != node.id or parsed.envelope.room_id != node.room_id:
                await websocket.close(code=4003, reason="Node identity mismatch")
                return
            if isinstance(parsed.payload, VoiceTurnStartPayload):
                if asr_stream is not None:
                    await asr_stream.abort()
                    asr_stream = None
                active_turn = parsed.payload.turn_id
                audio.clear()
                endpoint.reset()
                sequence += 1
                await _send_state(
                    websocket,
                    sequence=sequence,
                    node=node,
                    turn_id=active_turn,
                    state="listening",
                )
                open_asr_stream = getattr(websocket.app.state.voice_agent, "open_asr_stream", None)
                if callable(open_asr_stream):
                    try:
                        asr_stream = await open_asr_stream()
                    except Exception:
                        # 保留本地 PCM；结束时会按当前 provider 再尝试一次并返回标准错误状态。
                        asr_stream = None
            elif isinstance(parsed.payload, VoiceTurnStopPayload):
                if active_turn is None or parsed.payload.turn_id != active_turn:
                    continue
                turn_id = active_turn
                active_turn = None
                if parsed.payload.cancelled:
                    audio.clear()
                    if asr_stream is not None:
                        await asr_stream.abort()
                        asr_stream = None
                    sequence += 1
                    await _send_state(
                        websocket,
                        sequence=sequence,
                        node=node,
                        turn_id=turn_id,
                        state="idle",
                        continue_dialog=False,
                    )
                    continue
                captured = bytes(audio)
                audio.clear()
                completed_stream = asr_stream
                asr_stream = None
                sequence = await _process_voice_turn(
                    websocket,
                    sequence=sequence,
                    node=node,
                    turn_id=turn_id,
                    audio=captured,
                    asr_stream=completed_stream,
                    media_protocol_version=hello_payload.media_protocol_version,
                )
    except WebSocketDisconnect:
        pass
    finally:
        if asr_stream is not None:
            await asr_stream.abort()
