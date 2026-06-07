import time

import pytest

import stream_relay
from stream_relay import (
    StreamRelayError,
    register_relay,
    relay_paused,
    relay_stream,
    relay_token_from_url,
    toggle_relay,
)


def test_register_relay_returns_reusable_token(monkeypatch):
    monkeypatch.setattr(stream_relay.secrets, "token_urlsafe", lambda _: "token")
    stream_relay._relays.clear()

    token = register_relay({"video_url": "https://example.com/video"})

    assert token == "token"
    assert stream_relay._relays[token][1]["video_url"] == "https://example.com/video"
    assert relay_token_from_url("http://localhost/api/stream/relay/token") == "token"
    assert relay_paused(token) is False
    assert toggle_relay(token) is True
    assert relay_paused(token) is True
    assert toggle_relay(token) is False


async def test_expired_relay_is_rejected(monkeypatch):
    stream_relay._relays.clear()
    stream_relay._relays["expired"] = (
        time.monotonic() - stream_relay.config.STREAM_RELAY_TTL - 1,
        {},
    )

    with pytest.raises(StreamRelayError, match="expired"):
        await anext(relay_stream("expired"))


async def test_unknown_relay_is_rejected():
    stream_relay._relays.clear()

    with pytest.raises(StreamRelayError, match="not found"):
        await anext(relay_stream("missing"))
