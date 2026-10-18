import pytest
from fastapi.testclient import TestClient

from app import app

from .conftest import INTERLACE, PHONE

PROTECTED_ROUTES = [
    (method, route.path)
    for route in app.routes
    for method in route.methods
    if (method, route.path) not in {
        ("GET", "/api/health"),
        ("GET", "/api/stream/relay/{token}"),
        ("HEAD", "/api/stream/relay/{token}"),
    }
]


@pytest.mark.parametrize(("method", "path"), PROTECTED_ROUTES)
def test_routes_require_the_incandenza_header(headerless_client, method, path):
    response = headerless_client.request(method, path)

    assert response.status_code == 401
    if method != "HEAD":
        assert response.json()["detail"]


@pytest.mark.parametrize("value", ["", "   ", "\t"])
def test_a_blank_header_is_refused(headerless_client, value):
    assert headerless_client.get("/api/version", headers={"X-Incandenza": value}).status_code == 401


@pytest.mark.parametrize("value", ["1", "0", "anything", "  value  "])
def test_any_nonempty_header_value_is_accepted(headerless_client, value):
    response = headerless_client.get("/api/version", headers={"x-incandenza": value})

    assert response.status_code == 200
    assert response.json()["service"] == "interlace"


@pytest.mark.parametrize("peer", ["192.168.1.158", "10.0.0.2", "8.8.8.8", "::ffff:192.168.1.158", "testclient"])
def test_only_tailnet_and_loopback_peers_get_in(peer):
    outsider = TestClient(app, base_url=INTERLACE, client=(peer, 50000), headers={"X-Incandenza": "1"})

    response = outsider.get("/api/version")

    assert response.status_code == 403
    assert response.json()["detail"]


@pytest.mark.parametrize("peer", ["127.0.0.1", "::1", "100.109.138.18", "fd7a:115c:a1e0::1"])
def test_tailnet_and_loopback_peers_get_in(peer):
    insider = TestClient(app, base_url=INTERLACE, client=(peer, 50000), headers={"X-Incandenza": "1"})

    assert insider.get("/api/version").status_code == 200


@pytest.mark.parametrize("base_url", ["http://evil.example:8000", "http://interlace:8000"])
def test_a_hostname_is_refused(base_url):
    page = TestClient(app, base_url=base_url, client=PHONE, headers={"X-Incandenza": "1"})

    assert page.get("/api/version").status_code == 403


@pytest.mark.parametrize("base_url", [INTERLACE, "http://127.0.0.1:8000", "http://localhost:8000"])
def test_an_ip_or_localhost_is_accepted(base_url):
    insider = TestClient(app, base_url=base_url, client=PHONE, headers={"X-Incandenza": "1"})

    assert insider.get("/api/version").status_code == 200


def test_health_is_open(headerless_client):
    response = headerless_client.get("/api/health")

    assert response.status_code == 200
    assert response.json() == {"ok": True}


@pytest.mark.parametrize(("method", "path"), [
    ("HEAD", "/api/health"),
    ("POST", "/api/health"),
    ("OPTIONS", "/api/player"),
    ("POST", "/api/stream/relay/token"),
    ("GET", "/api/stream/relay/token/extra"),
])
def test_exceptions_do_not_open_other_methods_or_paths(headerless_client, method, path):
    assert headerless_client.request(method, path).status_code == 401


@pytest.mark.parametrize("method", ["GET", "HEAD"])
@pytest.mark.parametrize("host", ["192.0.2.10", "100.64.0.2", "localhost", "::ffff:192.0.2.10", None])
@pytest.mark.parametrize("with_header", [False, True])
def test_relay_refuses_non_loopback_peers(method, host, with_header):
    headers = {"X-Incandenza": "1"} if with_header else {}
    peer = (host, 50000) if host else None
    client = TestClient(app, client=peer, headers=headers)

    response = client.request(method, "/api/stream/relay/token", headers={"X-Forwarded-For": "127.0.0.1"})

    assert response.status_code == 403
    if method == "GET":
        assert response.json()["detail"]


@pytest.mark.parametrize("method", ["GET", "HEAD"])
@pytest.mark.parametrize("host", ["127.0.0.1", "127.0.0.2", "::1", "::ffff:127.0.0.1"])
def test_relay_serves_loopback_without_a_header(monkeypatch, method, host):
    async def relay(token):
        assert token == "token"
        yield b"media stream"

    monkeypatch.setattr("app.relay_stream", relay)
    client = TestClient(app, client=(host, 50000))

    response = client.request(method, "/api/stream/relay/token")

    assert response.status_code == 200
    assert response.headers["Content-Type"] == "video/x-matroska"
    assert response.content == (b"media stream" if method == "GET" else b"")


@pytest.mark.parametrize("path", ["/", "/assets/app.js", "/videos/movie.mp4", "/docs", "/redoc"])
def test_only_api_routes_are_served(client, path):
    assert client.get(path).status_code == 404
