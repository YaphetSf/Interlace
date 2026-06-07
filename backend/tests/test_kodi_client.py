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
        json={"jsonrpc": "2.0", "id": "ic", "result": "OK"},
    )
    result = await kodi.play_pause()
    assert result == "OK"


async def test_seek(kodi: Kodi, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": [{"playerid": 1, "type": "video"}]},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "OK"},
    )
    result = await kodi.seek(75.0)
    assert result == "OK"


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


async def test_kodi_error_response(kodi: Kodi, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "error": {"message": "kodi barfed"}},
    )
    with pytest.raises(RuntimeError, match="kodi barfed"):
        await kodi.play_file("/some/file.mkv")
