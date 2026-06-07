import time

import pytest

import stream_relay
from stream_relay import (
    StreamRelayError,
    _ffmpeg_command,
    register_relay,
    relay_paused,
    relay_stream,
    relay_token_from_url,
    release_relay,
    toggle_relay,
)


def test_ffmpeg_inputs_can_refill_relay_buffer(monkeypatch):
    monkeypatch.setattr(stream_relay.config, "STREAM_RELAY_READ_RATE", 1.25)
    monkeypatch.setattr(stream_relay.config, "STREAM_RELAY_INITIAL_BUFFER", 8)

    command = _ffmpeg_command(
        "/usr/bin/ffmpeg",
        {
            "video_url": "https://example.com/video",
            "audio_url": "https://example.com/audio",
            "headers": {"User-Agent": "Interlace test"},
        },
    )

    assert command.count("-readrate") == 2
    assert command.count("1.25") == 2
    assert command.count("-readrate_initial_burst") == 2
    assert command.count("8") == 2


def test_register_relay_returns_reusable_token(monkeypatch):
    monkeypatch.setattr(stream_relay.secrets, "token_urlsafe", lambda _: "token")
    stream_relay._relays.clear()
    stream_relay._active_relays.clear()

    token = register_relay({"video_url": "https://example.com/video"})

    assert token == "token"
    assert stream_relay._relays[token][1]["video_url"] == "https://example.com/video"
    assert relay_token_from_url("http://localhost/api/stream/relay/token") == "token"
    assert relay_paused(token) is False
    assert toggle_relay(token) is True
    assert relay_paused(token) is True
    assert toggle_relay(token) is False
    release_relay(token)
    assert relay_token_from_url("http://localhost/api/stream/relay/token") is None


async def test_expired_relay_is_rejected(monkeypatch):
    stream_relay._relays.clear()
    stream_relay._active_relays.clear()
    stream_relay._relays["expired"] = (
        time.monotonic() - stream_relay.config.STREAM_RELAY_TTL - 1,
        {},
    )

    with pytest.raises(StreamRelayError, match="expired"):
        await anext(relay_stream("expired"))


async def test_unknown_relay_is_rejected():
    stream_relay._relays.clear()
    stream_relay._active_relays.clear()

    with pytest.raises(StreamRelayError, match="not found"):
        await anext(relay_stream("missing"))


async def test_active_relay_does_not_expire(monkeypatch):
    stream_relay._relays.clear()
    stream_relay._active_relays.clear()
    stream_relay._relays["active"] = (
        time.monotonic() - stream_relay.config.STREAM_RELAY_TTL - 1,
        {},
    )
    stream_relay._active_relays.add("active")
    monkeypatch.setattr(stream_relay.config, "FFMPEG_PATH", "/missing/ffmpeg")
    monkeypatch.setattr(stream_relay.shutil, "which", lambda _: None)

    with pytest.raises(StreamRelayError, match="ffmpeg was not found"):
        await anext(relay_stream("active"))
