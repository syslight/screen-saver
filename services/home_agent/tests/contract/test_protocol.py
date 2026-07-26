from __future__ import annotations

import json
from pathlib import Path

import pytest

from home_agent.protocol.envelope import ProtocolValidationError, make_envelope, parse_envelope
from home_agent.protocol.messages import HeartbeatPayload


def fixtures() -> dict[str, list[dict[str, object]]]:
    path = Path(__file__).parents[4] / "packages" / "node_protocol" / "fixtures" / "messages.json"
    return json.loads(path.read_text(encoding="utf-8"))


def test_canonical_valid_messages_round_trip() -> None:
    for message in fixtures()["valid"]:
        parsed = parse_envelope(message)
        reparsed = parse_envelope(parsed.envelope.json_dict())
        assert reparsed.envelope.type == parsed.envelope.type


def test_canonical_invalid_messages_have_expected_code() -> None:
    for fixture in fixtures()["invalid"]:
        with pytest.raises(ProtocolValidationError) as caught:
            parse_envelope(fixture["message"])
        assert caught.value.code == fixture["code"]


def test_envelope_rejects_invalid_uuid_unknown_field_and_bad_camera_property() -> None:
    message = fixtures()["valid"][0].copy()
    message["nodeId"] = "not-a-uuid"
    with pytest.raises(ProtocolValidationError, match="envelope"):
        parse_envelope(message)

    message = fixtures()["valid"][0].copy()
    message["unexpected"] = True
    with pytest.raises(ProtocolValidationError):
        parse_envelope(message)

    message = json.loads(json.dumps(fixtures()["valid"][1]))
    message["payload"]["capabilities"][0]["properties"]["supportsStill"] = "yes"
    with pytest.raises(ProtocolValidationError) as caught:
        parse_envelope(message)
    assert caught.value.code == "invalid_payload"


def test_make_envelope_serializes_utc_and_aliases() -> None:
    envelope = make_envelope("heartbeat.ping", HeartbeatPayload(nonce="1"), sequence=1)
    encoded = envelope.json_dict()
    assert encoded["protocolVersion"] == 1
    assert encoded["sentAt"].endswith("Z")
