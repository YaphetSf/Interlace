import time

import pytest

import stream_relay
from stream_relay import (
    StreamRelayError,
    _ffmpeg_command,
    fork_relay,
    register_relay,
    relay_paused,
    relay_stream,
    relay_stream_info,
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
    # http(s) inputs must auto-reconnect so pauses and network blips
    # don't kill the stream
    assert command.count("-reconnect") == 2
    assert command.count("-reconnect_streamed") == 2


def test_ffmpeg_seeks_inputs_when_start_offset_is_set():
    stream = {
        "video_url": "https://example.com/video",
        "audio_url": "https://example.com/audio",
        "headers": {},
        "start_offset": 90.5,
    }

    command = _ffmpeg_command("/usr/bin/ffmpeg", stream)

    assert command.count("-ss") == 2
    assert command.count("90.500") == 2
    assert command.index("-ss") < command.index("-i")

    no_offset = _ffmpeg_command("/usr/bin/ffmpeg", {**stream, "start_offset": 0})
    assert "-ss" not in no_offset


def test_fork_relay_copies_stream_with_new_offset():
    stream_relay._relays.clear()
    stream_relay._relay_gates.clear()
    stream_relay._active_relays.clear()

    token = register_relay({"video_url": "https://example.com/video", "duration": 600.0})
    new_token = fork_relay(token, 120.0)

    assert new_token != token
    info = relay_stream_info(new_token)
    assert info["video_url"] == "https://example.com/video"
    assert info["duration"] == 600.0
    assert info["start_offset"] == 120.0
    # the original relay is untouched until the caller releases it
    assert "start_offset" not in relay_stream_info(token)

    with pytest.raises(StreamRelayError, match="not found"):
        fork_relay("missing", 0)


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
