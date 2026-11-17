import pytest


def test_file_full_range_and_head(client, mock_download_dir):
    video = mock_download_dir / "clip.mkv"
    video.write_bytes(b"0123456789")
    params = {"path": str(video)}

    response = client.get("/api/file", params=params)
    assert response.status_code == 200
    assert response.content == b"0123456789"
    assert response.headers["content-type"] == "video/x-matroska"
    assert response.headers["accept-ranges"] == "bytes"

    response = client.get("/api/file", params=params, headers={"Range": "bytes=2-5"})
    assert response.status_code == 206
    assert response.content == b"2345"
    assert response.headers["content-range"] == "bytes 2-5/10"

    response = client.head("/api/file", params=params)
    assert response.status_code == 200
    assert response.content == b""
    assert response.headers["content-length"] == "10"

    response = client.head("/api/file", params=params, headers={"Range": "bytes=2-5"})
    assert response.status_code == 206
    assert response.content == b""
    assert response.headers["content-range"] == "bytes 2-5/10"


@pytest.mark.parametrize(
    ("name", "status"),
    [
        ("/etc/passwd", 403),
        ("not-a-video.txt", 403),
        ("missing.mkv", 404),
        ("Movies.mkv", 404),
    ],
)
def test_file_rejects_invalid_paths(client, mock_download_dir, name, status):
    (mock_download_dir / "Movies.mkv").mkdir()
    path = name if name.startswith("/") else str(mock_download_dir / name)
    response = client.get("/api/file", params={"path": path})
    assert response.status_code == status


@pytest.mark.parametrize("method", ["GET", "HEAD"])
def test_file_requires_device_key(headerless_client, mock_download_dir, method):
    response = headerless_client.request(method, "/api/file", params={"path": str(mock_download_dir / "tv.mp4")})
    assert response.status_code == 401


@pytest.mark.parametrize(
    ("suffix", "media_type"),
    [
        (".srt", "application/x-subrip"),
        (".ass", "text/x-ssa"),
        (".ssa", "text/x-ssa"),
        (".vtt", "text/vtt"),
    ],
)
def test_file_serves_subtitles(client, mock_download_dir, suffix, media_type):
    path = mock_download_dir / f"tv{suffix}"
    path.write_bytes(b"subtitle")
    response = client.get("/api/file", params={"path": str(path)})
    assert response.status_code == 200
    assert response.content == b"subtitle"
    assert response.headers["content-type"].split(";")[0] == media_type


@pytest.mark.parametrize("route", ["subtitle", "thumbnail", "library", "delete", "file"])
def test_existing_routes_reject_symlink_escapes(client, mock_download_dir, tmp_path, route):
    outside = tmp_path.parent / f"{tmp_path.name}-outside"
    outside.mkdir()
    (outside / "video.mkv").write_bytes(b"outside")
    link = mock_download_dir / "escape"
    link.symlink_to(outside, target_is_directory=True)
    path = str(link / "video.mkv")
    if route == "subtitle":
        response = client.post("/api/upload/subtitle", data={"video_path": path}, files={"file": ("sub.srt", b"sub")})
    elif route == "library":
        response = client.get("/api/library", params={"path": "escape"})
    elif route == "delete":
        response = client.request("DELETE", "/api/library", json={"path": path})
    else:
        response = client.get(f"/api/{route}", params={"path": path})
    assert response.status_code == 403
    assert response.json() == {"detail": "Access denied: Path outside download directory."}
    assert (outside / "video.mkv").exists()


def test_root_can_be_listed_but_not_served_or_deleted(client, mock_download_dir):
    assert client.get("/api/library", params={"path": "."}).status_code == 200
    assert client.get("/api/file", params={"path": str(mock_download_dir)}).status_code == 403
    assert client.get("/api/thumbnail", params={"path": str(mock_download_dir)}).status_code == 403
    assert client.request("DELETE", "/api/library", json={"path": str(mock_download_dir)}).status_code == 403
