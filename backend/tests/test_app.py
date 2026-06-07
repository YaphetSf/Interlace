import httpx
from fastapi.testclient import TestClient
from pytest_httpx import HTTPXMock


def test_health(client: TestClient):
    r = client.get("/api/health")
    assert r.status_code == 200
    assert r.json() == {"ok": True}


def test_version(client: TestClient):
    r = client.get("/api/version")
    assert r.status_code == 200
    assert r.json()["service"] == "interlace-console"


def test_capabilities(client: TestClient):
    r = client.get("/api/capabilities")
    assert r.status_code == 200
    data = r.json()
    assert data["service"] == "interlace-console"
    assert "playback" in data["features"]
    assert "downloads" in data["features"]


def test_status(client: TestClient):
    r = client.get("/api/status")
    assert r.status_code == 200
    data = r.json()
    assert data["ok"] is True
    assert "server" in data


def test_library_default_dir(client, mock_download_dir):
    r = client.get("/api/library")
    assert r.status_code == 200
    data = r.json()
    assert "items" in data
    assert "disk" in data
    names = [item["name"] for item in data["items"]]
    assert "tv.mp4" in names
    assert "Movies" in names
    assert "downloading.mkv" not in names  # has .aria2 companion
    assert "not-a-video.txt" not in names  # wrong extension


def test_library_subdirectory(client, mock_download_dir):
    r = client.get("/api/library?path=Movies")
    assert r.status_code == 200
    data = r.json()
    names = [item["name"] for item in data["items"]]
    assert "test.mkv" in names


def test_library_path_traversal_blocked(client, mock_download_dir):
    r = client.get("/api/library?path=../../etc")
    assert r.status_code == 403


def test_delete_library_item(client, mock_download_dir):
    target = str(mock_download_dir / "tv.mp4")
    r = client.request("DELETE", "/api/library", json={"path": target})
    assert r.status_code == 200
    assert not (mock_download_dir / "tv.mp4").exists()


def test_delete_library_path_traversal_blocked(client, mock_download_dir):
    r = client.request("DELETE", "/api/library", json={"path": "/etc/passwd"})
    assert r.status_code == 403


def test_upload_path_traversal_blocked(client, mock_download_dir):
    r = client.post(
        "/api/upload",
        data={"path": "../../etc"},
        files={"file": ("test.txt", b"hello")},
    )
    assert r.status_code == 403


def test_upload_empty_filename(client, mock_download_dir):
    r = client.post(
        "/api/upload",
        files={"file": ("", b"hello")},
    )
    # FastAPI/Pydantic catches the empty filename before our handler
    assert r.status_code in (400, 422)


def test_subtitle_upload_invalid_extension(client, mock_download_dir):
    video_path = str(mock_download_dir / "tv.mp4")
    r = client.post(
        "/api/upload/subtitle",
        data={"video_path": video_path},
        files={"file": ("subs.txt", b"text")},
    )
    assert r.status_code == 400


def test_subtitle_upload_video_not_found(client, mock_download_dir):
    video_path = str(mock_download_dir / "nonexistent.mkv")
    r = client.post(
        "/api/upload/subtitle",
        data={"video_path": video_path},
        files={"file": ("subs.srt", b"1\n00:00:01 --> 00:00:02\nhello")},
    )
    assert r.status_code == 404


def test_subtitle_upload_path_traversal_blocked(client, mock_download_dir):
    r = client.post(
        "/api/upload/subtitle",
        data={"video_path": "/etc/passwd"},
        files={"file": ("subs.srt", b"")},
    )
    assert r.status_code == 403


def test_download_pause_returns_502_on_aria2_failure(client, httpx_mock: HTTPXMock):
    httpx_mock.add_exception(httpx.ConnectError("connection refused"))
    r = client.post("/api/downloads/fakegid/pause")
    assert r.status_code == 502


def test_download_remove_returns_502_on_aria2_failure(client, httpx_mock: HTTPXMock):
    httpx_mock.add_exception(httpx.ConnectError("connection refused"))
    r = client.request("DELETE", "/api/downloads/fakegid")
    assert r.status_code == 502


def test_player_returns_502_on_kodi_failure(client, httpx_mock: HTTPXMock):
    """When Kodi RPC is unreachable, player should return 502 not 500."""
    httpx_mock.add_exception(httpx.ConnectError("connection refused"))
    r = client.get("/api/player")
    assert r.status_code == 502


def test_playpause_returns_502_on_kodi_failure(client, httpx_mock: HTTPXMock):
    httpx_mock.add_exception(httpx.ConnectError("connection refused"))
    r = client.post("/api/player/playpause")
    assert r.status_code == 502


def test_stream_resolves_and_plays(client, monkeypatch):
    played = []

    async def resolve(url, quality):
        assert url == "https://example.com/watch/123"
        assert quality == "1080p"
        return {
            "mode": "direct",
            "url": "https://cdn.example.com/video.mp4",
            "title": "Example",
            "source": "ExampleSite",
            "quality": "1080p",
        }

    async def play(url):
        played.append(url)

    monkeypatch.setattr("app.resolve_stream", resolve)
    monkeypatch.setattr("app.kodi.play_stream", play)

    r = client.post("/api/stream", json={"url": "https://example.com/watch/123"})
    assert r.status_code == 200
    assert r.json() == {
        "ok": True,
        "title": "Example",
        "source": "ExampleSite",
        "quality": "1080p",
    }
    assert played == ["https://cdn.example.com/video.mp4"]


def test_stream_resolution_error_returns_400(client, monkeypatch):
    from app import StreamResolutionError

    async def resolve(url, quality):
        raise StreamResolutionError("unsupported URL")

    monkeypatch.setattr("app.resolve_stream", resolve)
    r = client.post("/api/stream", json={"url": "ftp://example.com/video"})
    assert r.status_code == 400
    assert "unsupported URL" in r.text


def test_seek_returns_502_on_kodi_failure(client, httpx_mock: HTTPXMock):
    httpx_mock.add_exception(httpx.ConnectError("connection refused"))
    r = client.post("/api/player/seek", json={"percentage": 50.0})
    assert r.status_code == 502


def test_volume_returns_502_on_kodi_failure(client, httpx_mock: HTTPXMock):
    httpx_mock.add_exception(httpx.ConnectError("connection refused"))
    r = client.post("/api/player/volume", json={"level": 80})
    assert r.status_code == 502
