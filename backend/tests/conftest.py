import pytest
from fastapi.testclient import TestClient

from app import app

INTERLACE = "http://100.119.149.49:8000"
PHONE = ("100.95.53.61", 50000)  # a phone arrives through an Xray VPS's tailnet address


@pytest.fixture
def client():
    return TestClient(app, base_url=INTERLACE, client=PHONE, headers={"X-Person": "ding"})


@pytest.fixture
def unnamed_client():
    return TestClient(app, base_url=INTERLACE, client=PHONE)


@pytest.fixture
def test_dir(tmp_path):
    """A temporary download directory with some video files and subdirectories."""
    (tmp_path / "Movies").mkdir(parents=True, exist_ok=True)
    (tmp_path / "Movies" / "test.mkv").write_text("mkv")
    (tmp_path / "tv.mp4").write_text("mp4")
    (tmp_path / "not-a-video.txt").write_text("text")
    (tmp_path / "downloading.mkv").write_text("mkv")
    (tmp_path / "downloading.mkv.aria2").write_text("")
    return tmp_path


@pytest.fixture
def mock_download_dir(monkeypatch, test_dir):
    monkeypatch.setattr("app.config.DOWNLOAD_DIR", test_dir)
    monkeypatch.setattr("app.config.DOWNLOAD_DIR", test_dir, raising=False)
    return test_dir
