import hashlib
import runpy

import pytest
from fastapi.testclient import TestClient

import config
from app import app

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
def test_routes_require_person_key(unauthenticated_client, person_key, method, path):
    response = unauthenticated_client.request(method, path)

    assert response.status_code == 401
    if method != "HEAD":
        assert response.json()["detail"]
    assert response.headers["WWW-Authenticate"] == "Bearer"


@pytest.mark.parametrize("authorization", ["Bearer wrong-key", "Basic wrong-key", "Bearer", "Bearer   "])
def test_wrong_or_malformed_key_is_refused(unauthenticated_client, person_key, authorization):
    response = unauthenticated_client.get("/api/version", headers={"Authorization": authorization})

    assert response.status_code == 401
    assert response.json()["detail"]


@pytest.mark.parametrize("scheme", ["Bearer", "bearer", "BEARER"])
def test_person_key_is_accepted(unauthenticated_client, person_key, scheme):
    response = unauthenticated_client.get(
        "/api/version", headers={"Authorization": f"{scheme}  {person_key}  "},
    )

    assert response.status_code == 200
    assert response.json()["service"] == "interlace"


def test_any_household_person_key_is_accepted(unauthenticated_client, monkeypatch):
    keys = ("first-person-key", "second-person-key")
    monkeypatch.setattr(config, "PERSON_KEYS_SHA256", tuple(hashlib.sha256(key.encode()).hexdigest() for key in keys))

    for key in keys:
        response = unauthenticated_client.get("/api/version", headers={"Authorization": f"Bearer {key}"})
        assert response.status_code == 200


def test_empty_key_configuration_refuses_requests(client, monkeypatch):
    monkeypatch.setattr(config, "PERSON_KEYS_SHA256", ())

    response = client.get("/api/version")

    assert response.status_code == 401
    assert response.json()["detail"]


@pytest.mark.parametrize("authorization", [None, "Bearer wrong-key"])
def test_health_is_open_with_empty_key_configuration(unauthenticated_client, monkeypatch, authorization):
    monkeypatch.setattr(config, "PERSON_KEYS_SHA256", ())
    headers = {"Authorization": authorization} if authorization else {}

    response = unauthenticated_client.get("/api/health", headers=headers)

    assert response.status_code == 200
    assert response.json() == {"ok": True}


@pytest.mark.parametrize(("method", "path"), [
    ("HEAD", "/api/health"),
    ("POST", "/api/health"),
    ("OPTIONS", "/api/player"),
    ("POST", "/api/stream/relay/token"),
    ("GET", "/api/stream/relay/token/extra"),
])
def test_exceptions_do_not_open_other_methods_or_paths(unauthenticated_client, person_key, method, path):
    assert unauthenticated_client.request(method, path).status_code == 401


@pytest.mark.parametrize("method", ["GET", "HEAD"])
@pytest.mark.parametrize("host", ["192.0.2.10", "100.64.0.2", "localhost", "::ffff:192.0.2.10", None])
@pytest.mark.parametrize("authenticated", [False, True])
def test_relay_refuses_non_loopback_peers(person_key, method, host, authenticated):
    headers = {"Authorization": f"Bearer {person_key}"} if authenticated else {}
    peer = (host, 50000) if host else None
    client = TestClient(app, client=peer, headers=headers)

    response = client.request(method, "/api/stream/relay/token", headers={"X-Forwarded-For": "127.0.0.1"})

    assert response.status_code == 403
    if method == "GET":
        assert response.json()["detail"]


@pytest.mark.parametrize("method", ["GET", "HEAD"])
@pytest.mark.parametrize("host", ["127.0.0.1", "127.0.0.2", "::1", "::ffff:127.0.0.1"])
def test_relay_serves_loopback_without_a_key(monkeypatch, method, host):
    monkeypatch.setattr(config, "PERSON_KEYS_SHA256", ())

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


@pytest.mark.parametrize("raw", [None, "", " , , ", "invalid", "non-ascii-\u00e9"])
def test_unset_empty_or_invalid_digest_configuration(monkeypatch, raw):
    monkeypatch.setattr("dotenv.load_dotenv", lambda *_: None)
    if raw is None:
        monkeypatch.delenv("PERSON_KEYS_SHA256", raising=False)
    else:
        monkeypatch.setenv("PERSON_KEYS_SHA256", raw)

    loaded = runpy.run_path(config.__file__)

    assert loaded["PERSON_KEYS_SHA256"] == ()


def test_digest_configuration_accepts_comma_separated_hex(monkeypatch):
    digests = tuple(hashlib.sha256(key.encode()).hexdigest() for key in ("first", "second"))
    monkeypatch.setenv("PERSON_KEYS_SHA256", f" {digests[0].upper()}, , {digests[1]} ")

    loaded = runpy.run_path(config.__file__)

    assert loaded["PERSON_KEYS_SHA256"] == digests
