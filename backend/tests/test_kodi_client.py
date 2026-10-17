import pytest
from pytest_httpx import HTTPXMock

from kodi_client import Kodi


@pytest.fixture
def kodi():
    return Kodi()


async def test_ping(kodi: Kodi, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "pong"},
    )
    result = await kodi._call("JSONRPC.Ping")
    assert result == "pong"


async def test_play_file(kodi: Kodi, httpx_mock: HTTPXMock):
    calls = []

    async def call(method, params=None):
        calls.append((method, params))
        if method == "Playlist.GetItems":
            return {"items": [{"file": "/path/to/video.mkv"}]}
        return "OK"

    kodi._call = call
    result = await kodi.play_file("/path/to/video.mkv")

    assert result == "OK"
    assert calls == [
        ("Playlist.Clear", {"playlistid": 1}),
        (
            "Playlist.Add",
            {
                "playlistid": 1,
                "item": {"directory": "/path/to/", "media": "video"},
            },
        ),
        (
            "Playlist.GetItems",
            {"playlistid": 1, "properties": ["file"]},
        ),
        ("Player.Open", {"item": {"playlistid": 1, "position": 0}}),
    ]


async def test_play_stream(kodi: Kodi, httpx_mock: HTTPXMock):
    calls = []

    async def call(method, params=None):
        calls.append((method, params))
        return "OK"

    kodi._call = call
    result = await kodi.play_stream("https://cdn.example.com/video.m3u8")

    assert result == "OK"
    assert calls == [
        ("Playlist.Clear", {"playlistid": 1}),
        (
            "Playlist.Add",
            {
                "playlistid": 1,
                "item": {"file": "https://cdn.example.com/video.m3u8"},
            },
        ),
        ("Player.Open", {"item": {"playlistid": 1, "position": 0}}),
    ]


async def test_now_playing_active(kodi: Kodi, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": {"volume": 80, "muted": False}},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": [{"playerid": 1, "type": "video"}]},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": {
            "percentage": 50.0, "time": {"hours": 0, "minutes": 10, "seconds": 0},
            "totaltime": {"hours": 0, "minutes": 20, "seconds": 0},
            "speed": 1, "audiostreams": [], "currentaudiostream": {},
            "videostreams": [], "currentvideostream": {},
            "subtitles": [], "currentsubtitle": {}, "subtitleenabled": False,
        }},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": {"item": {"title": "Test Video", "file": "/path/to/video.mkv"}}},
    )
    state = await kodi.now_playing()
    assert state["active"] is True
    assert state["title"] == "Test Video"
    assert state["percentage"] == 50.0
    assert state["time"] == 600
    assert state["totaltime"] == 1200


async def test_now_playing_no_active_player(kodi: Kodi, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": {"volume": 50, "muted": True}},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": []},
    )
    state = await kodi.now_playing()
    assert state["active"] is False
    assert state["volume"] == 50
    assert state["muted"] is True


async def test_play_pause(kodi: Kodi, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": [{"playerid": 1, "type": "video"}]},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": {"item": {"file": "/path/to/video.mkv"}}},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "OK"},
    )
    result = await kodi.play_pause()
    assert result == "OK"


async def test_play_pause_toggles_relay(kodi: Kodi, monkeypatch):
    calls = []

    async def call(method, params=None):
        calls.append((method, params))
        if method == "Player.GetActivePlayers":
            return [{"playerid": 1, "type": "video"}]
        return {"item": {"file": "http://127.0.0.1:8000/api/stream/relay/token"}}

    kodi._call = call
    monkeypatch.setattr("kodi_client.relay_token_from_url", lambda _: "token")
    monkeypatch.setattr("kodi_client.toggle_relay", lambda _: True)

    result = await kodi.play_pause()

    assert result == {"paused": True}
    assert all(method != "Player.PlayPause" for method, _ in calls)


async def test_seek(kodi: Kodi, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": [{"playerid": 1, "type": "video"}]},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": {"item": {"file": "/path/to/video.mkv"}}},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "OK"},
    )
    result = await kodi.seek(75.0)
    assert result == "OK"


async def test_seek_relay_restarts_relay_at_offset(kodi: Kodi, monkeypatch):
    calls = []

    async def call(method, params=None):
        calls.append((method, params))
        if method == "Player.GetActivePlayers":
            return [{"playerid": 1, "type": "video"}]
        if method == "Player.GetItem":
            return {"item": {"file": "http://127.0.0.1:8000/api/stream/relay/old"}}
        return "OK"

    kodi._call = call
    forked = {}

    def fake_fork(token, offset):
        forked["offset"] = offset
        return "new"

    monkeypatch.setattr("kodi_client.relay_token_from_url", lambda _: "old")
    monkeypatch.setattr("kodi_client.relay_stream_info", lambda _: {"duration": 600.0})
    monkeypatch.setattr("kodi_client.fork_relay", fake_fork)
    monkeypatch.setattr("kodi_client.relay_playback_url", lambda token: f"http://127.0.0.1:8000/api/stream/relay/{token}")
    released = []
    monkeypatch.setattr("kodi_client.release_relay", released.append)

    result = await kodi.seek(50.0)

    assert result == {"seconds": 300}
    assert forked["offset"] == 300.0
    assert released == ["old"]
    # Kodi was pointed at the new relay URL instead of being asked to seek
    assert ("Playlist.Add", {"playlistid": 1, "item": {"file": "http://127.0.0.1:8000/api/stream/relay/new"}}) in calls
    assert all(method != "Player.Seek" for method, _ in calls)


async def test_now_playing_relay_reports_absolute_position(kodi: Kodi, monkeypatch):
    async def call(method, params=None):
        if method == "Application.GetProperties":
            return {"volume": 80, "muted": False}
        if method == "Player.GetActivePlayers":
            return [{"playerid": 1, "type": "video"}]
        if method == "Player.GetProperties":
            return {
                "percentage": 99.0,  # bogus: Kodi can't know the pipe's duration
                "time": {"hours": 0, "minutes": 1, "seconds": 30},
                "totaltime": {"hours": 0, "minutes": 0, "seconds": 0},
                "speed": 1,
            }
        return {"item": {"file": "http://127.0.0.1:8000/api/stream/relay/tok"}}

    kodi._call = call
    monkeypatch.setattr("kodi_client.relay_token_from_url", lambda _: "tok")
    monkeypatch.setattr("kodi_client.relay_paused", lambda _: False)
    monkeypatch.setattr(
        "kodi_client.relay_stream_info",
        lambda _: {"duration": 600.0, "start_offset": 210.0},
    )

    state = await kodi.now_playing()

    assert state["time"] == 300  # 210s offset + 90s played
    assert state["totaltime"] == 600
    assert state["percentage"] == 50.0


async def test_set_volume(kodi: Kodi, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": 90},
    )
    result = await kodi.set_volume(90)
    assert result == 90


async def test_set_mute(kodi: Kodi, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "OK"},
    )
    result = await kodi.set_mute(True)
    assert result == "OK"


async def test_exec_action(kodi: Kodi, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "OK"},
    )
    result = await kodi.exec_action("subtitledelayplus")
    assert result == "OK"


async def test_add_subtitle_to_matching_video(kodi: Kodi):
    calls = []

    async def call(method, params=None):
        calls.append((method, params))
        if method == "Player.GetActivePlayers":
            return [{"playerid": 1, "type": "video"}]
        if method == "Player.GetItem":
            return {"item": {"file": "/videos/movie.mp4"}}
        return "OK"

    kodi._call = call
    assert await kodi.add_subtitle("/videos/movie.mp4", "/videos/movie.srt") is True
    assert calls[-1] == (
        "Player.AddSubtitle",
        {"playerid": 1, "subtitle": "/videos/movie.srt"},
    )


async def test_add_subtitle_skips_unrelated_video(kodi: Kodi):
    calls = []

    async def call(method, params=None):
        calls.append(method)
        if method == "Player.GetActivePlayers":
            return [{"playerid": 1, "type": "video"}]
        return {"item": {"file": "/videos/other.mp4"}}

    kodi._call = call
    assert await kodi.add_subtitle("/videos/movie.mp4", "/videos/movie.srt") is False
    assert "Player.AddSubtitle" not in calls


async def test_kodi_error_response(kodi: Kodi, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "error": {"message": "kodi barfed"}},
    )
    with pytest.raises(RuntimeError, match="kodi barfed"):
        await kodi.play_file("/some/file.mkv")
