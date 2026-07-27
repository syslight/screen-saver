from __future__ import annotations

import struct

from home_agent.services.voice_endpoint import VoiceEndpointDetector, VoiceEndpointEvent


def _pcm(value: int, milliseconds: int) -> bytes:
    count = 16_000 * milliseconds // 1_000
    return struct.pack(f"<{count}h", *([value] * count))


def test_detects_speech_then_trailing_silence() -> None:
    detector = VoiceEndpointDetector()

    assert detector.process(_pcm(2_000, 60)) is VoiceEndpointEvent.NONE
    assert detector.process(_pcm(2_000, 60)) is VoiceEndpointEvent.SPEECH_STARTED
    assert detector.process(_pcm(0, 600)) is VoiceEndpointEvent.NONE
    assert detector.process(_pcm(0, 100)) is VoiceEndpointEvent.ENDPOINT


def test_times_out_when_no_one_speaks() -> None:
    detector = VoiceEndpointDetector(no_speech_timeout_ms=100)

    assert detector.process(_pcm(0, 50)) is VoiceEndpointEvent.NONE
    assert detector.process(_pcm(0, 50)) is VoiceEndpointEvent.NO_SPEECH_TIMEOUT


def test_caps_a_long_utterance() -> None:
    detector = VoiceEndpointDetector(minimum_speech_ms=20, maximum_duration_ms=100)

    assert detector.process(_pcm(2_000, 20)) is VoiceEndpointEvent.SPEECH_STARTED
    assert detector.process(_pcm(2_000, 80)) is VoiceEndpointEvent.MAXIMUM_DURATION
