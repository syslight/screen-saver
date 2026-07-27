from __future__ import annotations

import math
import sys
from array import array
from enum import StrEnum


class VoiceEndpointEvent(StrEnum):
    NONE = "none"
    SPEECH_STARTED = "speech_started"
    ENDPOINT = "endpoint"
    NO_SPEECH_TIMEOUT = "no_speech_timeout"
    MAXIMUM_DURATION = "maximum_duration"


class VoiceEndpointDetector:
    """Server-side endpoint detector for 16 kHz mono signed PCM.

    Room nodes only stream microphone bytes.  All speech-boundary decisions stay
    in Home Agent so detector implementations can be replaced without updating
    Android devices.
    """

    def __init__(
        self,
        *,
        sample_rate: int = 16_000,
        minimum_speech_ms: float = 120,
        trailing_silence_ms: float = 700,
        no_speech_timeout_ms: float = 8_000,
        maximum_duration_ms: float = 12_000,
        minimum_rms: float = 420,
        noise_multiplier: float = 2.8,
    ) -> None:
        self.sample_rate = sample_rate
        self.minimum_speech_ms = minimum_speech_ms
        self.trailing_silence_ms = trailing_silence_ms
        self.no_speech_timeout_ms = no_speech_timeout_ms
        self.maximum_duration_ms = maximum_duration_ms
        self.minimum_rms = minimum_rms
        self.noise_multiplier = noise_multiplier
        self.reset()

    def reset(self) -> None:
        self._elapsed_ms = 0.0
        self._loud_ms = 0.0
        self._silence_ms = 0.0
        self._noise_floor = 120.0
        self._speech_started = False

    def process(self, pcm: bytes) -> VoiceEndpointEvent:
        samples = _pcm16_samples(pcm)
        if not samples:
            return VoiceEndpointEvent.NONE
        chunk_ms = len(samples) * 1_000 / self.sample_rate
        self._elapsed_ms += chunk_ms
        rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
        threshold = max(self.minimum_rms, self._noise_floor * self.noise_multiplier)
        loud = rms >= threshold

        if not self._speech_started:
            if loud:
                self._loud_ms += chunk_ms
            else:
                self._loud_ms = 0
                self._noise_floor = self._noise_floor * 0.92 + rms * 0.08
            if self._loud_ms >= self.minimum_speech_ms:
                self._speech_started = True
                self._silence_ms = 0
                return VoiceEndpointEvent.SPEECH_STARTED
            if self._elapsed_ms >= self.no_speech_timeout_ms:
                return VoiceEndpointEvent.NO_SPEECH_TIMEOUT
            return VoiceEndpointEvent.NONE

        if loud:
            self._silence_ms = 0
        else:
            self._silence_ms += chunk_ms
            if self._silence_ms >= self.trailing_silence_ms:
                return VoiceEndpointEvent.ENDPOINT
        if self._elapsed_ms >= self.maximum_duration_ms:
            return VoiceEndpointEvent.MAXIMUM_DURATION
        return VoiceEndpointEvent.NONE


def _pcm16_samples(pcm: bytes) -> array[int]:
    even_length = len(pcm) - len(pcm) % 2
    if even_length == 0:
        return array("h")
    samples = array("h")
    samples.frombytes(pcm[:even_length])
    if sys.byteorder != "little":
        samples.byteswap()
    return samples
