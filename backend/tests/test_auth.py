import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from app import api, app
from auth import Device, DeviceRegistry, require_device

from .conftest import DEVICE_KEY, write_registry

PROTECTED_ROUTES = [
    (method, route.path)
    for route in api.routes
    for method in route.methods
]


@pytest.mark.parametrize(("method", "path"), PROTECTED_ROUTES)
def test_routes_require_a_device_key(headerless_client, method, path):
    response = headerless_client.request(method, path)

    assert response.status_code == 401
    assert response.json() == {"detail": "device key required"}


@pytest.mark.parametrize("path", ["/api/status", "/api/health"])
@pytest.mark.parametrize("authorization", [None, "", "Bearer", "Bearer ", "Bearer unknown", f"Basic {DEVICE_KEY}"])
def test_missing_or_unknown_keys_are_refused(headerless_client, path, authorization):
    headers = {"Authorization": authorization} if authorization is not None else {}
    response = headerless_client.get(path, headers=headers)

    assert response.status_code == 401
    assert response.json() == {"detail": "device key required"}


@pytest.mark.parametrize("path", ["/api/status", "/api/health"])
def test_revocation_takes_effect_on_the_next_request(client, device_registry, path):
    assert client.get(path).status_code == 200
    write_registry(device_registry.path, [])

    response = client.get(path)

    assert response.status_code == 401
    assert response.json() == {"detail": "device key required"}


def test_new_devices_take_effect_on_the_next_request(headerless_client, device_registry):
    headers = {"Authorization": "Bearer newly-added-key"}
    assert headerless_client.get("/api/status", headers=headers).status_code == 401
    write_registry(device_registry.path, [("newly-added-key", "new phone", True)])

    assert headerless_client.get("/api/status", headers=headers).status_code == 200


@pytest.mark.parametrize("peer", ["192.168.1.158", "10.0.0.2", "8.8.8.8", "::ffff:192.168.1.158", "testclient", "::1"])
@pytest.mark.parametrize("path", ["/api/status", "/api/health"])
def test_a_valid_key_is_served_regardless_of_peer_or_host(peer, path):
    client = TestClient(
        app, base_url="http://tv.example.test:8000", client=(peer, 50000),
        headers={"Authorization": f"Bearer {DEVICE_KEY}"},
    )

    assert client.get(path).status_code == 200


def test_the_marker_header_does_not_authenticate(headerless_client):
    response = headerless_client.get("/api/status", headers={"X-Incandenza": "1"})

    assert response.status_code == 401
    assert response.json() == {"detail": "device key required"}


@pytest.mark.parametrize("admin", [True, False])
def test_dependency_returns_the_registered_identity(device_registry, admin):
    write_registry(device_registry.path, [(DEVICE_KEY, "named phone", admin)])
    identity_app = FastAPI()

    @identity_app.get("/")
    def identity(device: Device = Depends(require_device)):
        return device

    response = TestClient(identity_app).get("/", headers={"Authorization": f"bearer {DEVICE_KEY}"})

    assert response.status_code == 200
    assert response.json() == {"name": "named phone", "admin": admin}


def test_registry_is_read_at_initialization(device_registry, monkeypatch):
    def unexpected_load(source):
        pytest.fail("Unchanged registry was read again")

    monkeypatch.setattr("auth.tomllib.load", unexpected_load)

    assert device_registry.verify(DEVICE_KEY) == Device(name="test phone", admin=False)


@pytest.mark.parametrize("content", [None, "invalid toml", "device = 1", '[[device]]\nname = "broken"'])
def test_unreadable_registry_revokes_cached_devices(client, device_registry, content):
    assert client.get("/api/status").status_code == 200
    device_registry.path.unlink()
    if content is not None:
        device_registry.path.write_text(content)

    assert client.get("/api/status").status_code == 401


def test_a_missing_registry_can_be_created_later(tmp_path):
    path = tmp_path / "new-devices.toml"
    registry = DeviceRegistry(path)
    assert registry.verify(DEVICE_KEY) is None
    write_registry(path, [(DEVICE_KEY, "phone", False)])

    assert registry.verify(DEVICE_KEY) == Device(name="phone", admin=False)


@pytest.mark.parametrize("method", ["GET", "HEAD"])
@pytest.mark.parametrize("host", ["192.168.1.158", "100.64.0.2", "localhost", "::ffff:192.0.2.10", None])
@pytest.mark.parametrize("with_key", [False, True])
def test_relay_refuses_non_loopback_peers(method, host, with_key):
    headers = {"Authorization": f"Bearer {DEVICE_KEY}"} if with_key else {}
    peer = (host, 50000) if host else None
    client = TestClient(app, client=peer, headers=headers)

    response = client.request(method, "/api/stream/relay/token", headers={"X-Forwarded-For": "127.0.0.1"})

    assert response.status_code == 403
    if method == "GET":
        assert response.json() == {"detail": "Stream relay requires a loopback peer"}


@pytest.mark.parametrize("method", ["GET", "HEAD"])
@pytest.mark.parametrize("host", ["127.0.0.1", "127.0.0.2", "::1", "::ffff:127.0.0.1"])
def test_relay_serves_loopback_without_a_key(monkeypatch, method, host):
    async def relay(token):
        assert token == "token"
        yield b"media stream"

    monkeypatch.setattr("app.relay_stream", relay)
    client = TestClient(app, client=(host, 50000))

    response = client.request(method, "/api/stream/relay/token")

    assert response.status_code == 200
    assert response.headers["Content-Type"] == "video/x-matroska"
    assert response.content == (b"media stream" if method == "GET" else b"")


@pytest.mark.parametrize("path", ["/", "/assets/app.js", "/videos/movie.mp4", "/docs", "/redoc", "/openapi.json"])
def test_only_api_routes_are_served(client, path):
    assert client.get(path).status_code == 404
