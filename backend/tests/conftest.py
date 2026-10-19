import hashlib
import json
import os
import secrets

import pytest
from fastapi.testclient import TestClient

from app import app
from auth import DeviceRegistry

INTERLACE = "http://100.119.149.49:8000"
PHONE = ("192.168.1.158", 50000)
DEVICE_KEY = secrets.token_urlsafe(20)


def write_registry(path, devices):
    previous_mtime = path.stat().st_mtime_ns if path.exists() else 0
    path.write_text("\n".join(
        f'[[device]]\nname = {json.dumps(name)}\nsha256 = "{hashlib.sha256(key.encode()).hexdigest()}"\nadmin = {str(admin).lower()}\n'
        for key, name, admin in devices
    ))
    mtime = max(path.stat().st_mtime_ns, previous_mtime + 1)
    os.utime(path, ns=(mtime, mtime))


@pytest.fixture(autouse=True)
def device_registry(monkeypatch, tmp_path):
    path = tmp_path / "devices.toml"
    write_registry(path, [(DEVICE_KEY, "test phone", False)])
    registry = DeviceRegistry(path)
    monkeypatch.setattr("auth.registry", registry)
    return registry


@pytest.fixture
def client():
    return TestClient(app, base_url=INTERLACE, client=PHONE, headers={"Authorization": f"Bearer {DEVICE_KEY}"})


@pytest.fixture
def headerless_client():
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
